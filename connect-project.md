# Spec: connecting a new project to Claude Code Docker

This document is a task spec for the Claude Code agent. Walk through the steps, analyze the project, agree on architectural decisions with the user, create the artifacts, then verify.

## Infrastructure context

The setup is split into two parts:

**Shared infrastructure** (lives in the setup repo):
- `<setup>/Dockerfile` — `cc-image` (the CC container base image).
- `<setup>/bin/ccd` — wrapper: walks up from `$PWD` to the ancestor that has `<setup>/<basename(ancestor)>/ccd-config.sh`, then launches the CC container for that project. The config lives in the setup repo, not in the project bind-mount (security: otherwise CC could change its own flags from inside the session).
- `<setup>/cc-docker-proxy/haproxy.cfg` — config for the docker-API proxy (`tecnativa/docker-socket-proxy` + a custom deny rule on `/containers/create`); the root `init.sh` brings it up as the `cc-docker-proxy` container in `cc-net`. CC sessions talk to the docker daemon only through it (`DOCKER_HOST=tcp://cc-docker-proxy:2375`).
- `<setup>/lib/init-helpers.sh` — bash helper functions (logging, idempotent docker checks).
- `<setup>/init.sh` — root initializer: prerequisites, the shared `cc-net` network, the `claude-auth` volume, the `cc-docker-proxy` container, building `cc-image`, PATH wiring in `~/.bashrc`, then iterating `<setup>/*/init.sh`.

**Project settings** (NOT in the setup repo — local to each machine):
- `<setup>/<project-name>/` — settings folder for a specific connected project. Paired with `<projects-root>/<project-name>/` (same name).

The root `init.sh` iterates `<setup>/*/init.sh`. A folder is identified by the presence of `init.sh` inside it. Folders without `init.sh` (`bin/`, `lib/`, `cc-docker-proxy/`) are skipped silently.

## Conventions

- The name `<setup>/<project-name>/` MUST match the name of `<projects-root>/<project-name>/`. The setup folder name is how the linked project gets located.
- Project image (if `cc-image` needs extending): `cc-image-<project-name>`.
- Project service containers: `cc-<project-name>-<service>` (e.g. `cc-expro-vpn`).
- Service container images: `cc-<project-name>-<service>-image`.

## Inputs

Ask the user for:
1. `<project-name>` — the project folder name (must match the folder in `<projects-root>`).
2. Confirmation that `<projects-root>/<project-name>/` exists and is ready (repo cloned, dependencies installed).

## Step 1. Analyze the project

Read `<projects-root>/<project-name>/` and figure out what the project init.sh needs.

### 1.1. Compose networks
```bash
find <projects-root>/<project-name> -maxdepth 4 -name 'docker-compose*.y*ml' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*'
```
Read each file, extract network names (the `networks:` section). Compose typically names networks `<stack-folder>_<network>` (unless `name:` is set explicitly). Record the list — this becomes the `COMPOSE_NETWORKS` array in `ccd-config.sh`.

### 1.2. Host-bound scripts
```bash
find <projects-root>/<project-name> -maxdepth 3 -name '*.sh' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*'
```
Read each one. Signs of a host-bound script:
- `127.0.0.1` or `localhost` for DB/services;
- `./vpn-on.sh`, `./vpn-off.sh`, other host-only utilities;
- absolute paths into `/home/<user>/...` or `/etc/...`;
- assumes execution from the host, not from a container.

Each such script is a candidate for adaptation (Step 6).

### 1.3. VPN/tunnel to remote infrastructure
If scripts or configs reference an external host via `127.0.0.1:<port>` (the typical sign of an SSH tunnel or socat relay on the host), and the real host is not directly reachable from the container network — **a service VPN container is needed** in the shared `cc-net` network. Container name: `cc-<project-name>-vpn`. Typical implementation: xray + socat inside the service container. Templates: `<setup>/lib/project-template/Dockerfile.vpn` and `<setup>/lib/project-template/vpn-entrypoint.sh` — copied into `<setup>/<project-name>/` unchanged; project-specific customization goes only into `vpn-config/config.json` (xray config with the real upstream) and the `DB_REMOTE_HOST`/`DB_REMOTE_PORT` variables in the `docker create` call inside the project init.sh. The skeleton init.sh that builds such a container is `<setup>/lib/project-template/init.sh`.

### 1.4. System requirements
What the project uses that is not in the base `cc-image`:
- Playwright/Cypress — browser libs + Chromium. Under `--cap-drop=ALL` (the ccd default) chromium fails to set up its sandbox: launch with `chromiumSandbox: false` in `launchOptions` of the playwright `--config` file. Do NOT pass `--browser=chromium` (not a valid MCP CLI value — chromium is the default) and do NOT use `--browser-arg` (does not exist). For dev domains pointing at a host-side nginx-proxy (typical `127.0.0.1 *.lc` in host `/etc/hosts`, absent in the container), pass `--host-resolver-rules=MAP *.<tld> <proxy-service-name>` via `launchOptions.args`. Reference end-to-end setup: `<setup>/wiam/{Dockerfile,mcp.json}` + `<projects-root>/wiam/.claude/playwright-mcp-config.json`.
- `psql`, `mysql`, `mongo` clients;
- `nc`, `redis-cli`, `kubectl`, `aws` CLI;
- runtimes (php, python, ruby, go) — if you need to run the project's CLI inside the CC container.

Anything beyond `cc-image` → a separate `<setup>/<project-name>/Dockerfile` (FROM cc-image). A template with commented-out extension examples (postgres-client, Playwright, etc.) is at `<setup>/lib/project-template/Dockerfile`.

### 1.5. Sources of secrets on the host
- `.env` files in the project;
- backups in `temp-backup/` (if a migration was done);
- the user's ENV variables.

For each source — confirm with the user.

## Step 2. Architecture decisions (agree with the user)

Based on Step 1, ask the user separate questions:

| Decision | When needed |
|---|---|
| `<setup>/<project-name>/Dockerfile` (cc-image-<project-name>) | Step 1.4 found non-default requirements |
| Service container (Dockerfile.<svc> + entrypoint + config) | Step 1.3 found a VPN/tunnel OR the project needs a dedicated service |
| Non-empty `COMPOSE_NETWORKS` | Step 1.1 found compose networks CC must attach to |
| Adapt scripts in `.claude/scripts/` | Step 1.2 found host-bound scripts that should run from the CC container |
| `<projects-root>/<project-name>/.claude/<name>-credentials.env` | The project has passwords/keys the scripts need |

If nothing beyond the base is needed, `<setup>/<project-name>/` only contains a minimal `init.sh` that generates `ccd-config.sh` (with empty `COMPOSE_NETWORKS=()` and empty `VPN_CONTAINER`).

**Do not act blindly**: at every decision, explicitly show the user what you found in Step 1, what you propose to do, and wait for confirmation.

## Step 3. Create the folder structure

Inside `<setup>/<project-name>/`:
```
init.sh                         # required
ccd-config.sh                   # generated by init.sh; the wrapper config lives in the setup repo, not in the project bind-mount — otherwise CC from a session could rewrite its own EXPOSE_GIT_* flags
mcp.json                        # generated empty by init.sh; project-level MCP servers. Source of truth lives here, not in <projects-root>/.../.mcp.json (read-only bind-mount + --strict-mcp-config in ccd → anti-tampering)
[Dockerfile]                    # optional
[Dockerfile.<svc>]              # optional
[<svc>-entrypoint.sh]           # optional
[<svc>-config/]                 # optional (secrets inside)
```

Inside `<projects-root>/<project-name>/.claude/`:
```
[<name>-credentials.env]        # generated by init.sh, chmod 600
[<mcp-server>-config.json]      # generated by init.sh, per-MCP-server config (e.g. playwright-mcp-config.json) — referenced from mcp.json by absolute path
[scripts/]                      # adapted scripts, if any
```

`bin/ccd` only bind-mounts `<setup>/<project-name>/mcp.json` from the setup folder into the container (read-only, at `/home/claude/.config/ccd/mcp.json`). Anything else an MCP server needs (its own `--config <path>` file) lives in `<projects-root>/<project-name>/.claude/` — it is visible to the container through the project bind-mount, and `mcp.json` references it by absolute path.

`<setup>/<project-name>/` is excluded from the setup repo whitelist as a whole — secrets inside are safe.

`<projects-root>/<project-name>/` is a separate project repo (if it is a git repo). In that case its `.gitignore` MUST ignore `db-credentials.env` (or whatever `*-credentials.env` you use) and any `*.env`. The project init.sh, when generating the credentials file, **MUST emit a warning** about this. If the project is not a git repo, the rule does not apply — secrets in `.claude/` are local by design.

## Step 4. Implement `<setup>/<project-name>/init.sh`

A full working example with a VPN container is `<setup>/lib/project-template/init.sh`. The project name in the template is `expro` (example project); when adapting, replace `expro` with `<project-name>`, `EXPRO_*` variables with `<PROJECT_NAME>_*`, adjust `COMPOSE_NETWORKS` and `DB_REMOTE_HOST`, drop the VPN/credentials blocks if the project does not need them. The template's neighboring files (`Dockerfile`, `Dockerfile.vpn`, `vpn-entrypoint.sh`, `mcp.json`) are copied into `<setup>/<project-name>/` as needed — see Step 3.

Minimal skeleton (no VPN, no project Dockerfile, no credentials):

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
SETUP_DIR=$(dirname "$SCRIPT_DIR")
PROJECTS_ROOT=$(dirname "$SETUP_DIR")
PROJECT_NAME=$(basename "$SCRIPT_DIR")
PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"

source "$SETUP_DIR/lib/init-helpers.sh"

REBUILD=0
REBUILD_BASE_DERIVED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)              REBUILD=1; shift ;;
        --rebuild-base-derived) REBUILD_BASE_DERIVED=1; shift ;;
        *) cc_die "$PROJECT_NAME/init.sh: unknown flag $1" ;;
    esac
done

# 1. Validation: PROJECT_DIR must exist
[ -d "$PROJECT_DIR" ] || cc_die "project $PROJECT_DIR not found"
cc_log_skip "project found: $PROJECT_DIR"

# 2. Copy secrets into <setup>/<project-name>/<svc>-config/ (if needed)
# 3. Build cc-image-<project-name> (if a Dockerfile exists, FROM cc-image)
# 4. Build cc-<project-name>-<svc>-image (if a Dockerfile.<svc> exists, may be FROM any base)
# 5. Generate <name>-credentials.env (chmod 600) — only if the file is missing, otherwise SKIP
# 6. Generate ccd-config.sh — only if the file is missing, otherwise SKIP with a missing-fields check
# 7. Generate mcp.json (empty `{"mcpServers": {}}`) — only if the file is missing, otherwise SKIP
# 7.1. Generate per-MCP-server configs in $PROJECT_DIR/.claude/<server>-config.json — only if missing,
#      otherwise SKIP (same idempotency contract). Referenced from mcp.json by absolute path.
#      Reference: <setup>/wiam/init.sh section 6.6 (playwright-mcp-config.json).
# 8. Create service containers (`docker create` without run, idempotent via rm -f + create)

cc_log_ok "$PROJECT_NAME/init.sh: ok"
```

### Idempotency
Every resource — `inspect → SKIP / create`. No unconditional actions that would clobber existing state.

### Do not overwrite existing configs
`ccd-config.sh` and `<name>-credentials.env` are written ONLY when missing. If the file exists, compare its set of required keys against the template inside init.sh; on mismatch, emit `cc_log_info` with diagnostics and the user updates by hand.

### Flag cascade
- `--rebuild` → rebuild ALL project images (including service containers based on a different image). Re-create service containers.
- `--rebuild-base-derived` (forwarded by the root init.sh on a `cc-image` UID/GID drift) → rebuild ONLY images that are `FROM cc-image`. Service images on a different base (`debian:bookworm-slim`, etc.) are NOT touched. Service containers are also not re-created (their image did not change).

### Secret sources — explicit branches, no magic
For each secret: an explicit list of source priorities (ENV variables → project `.env` file → backup → fail with instructions). Each source is its own code branch.

## Step 5. Generate `ccd-config.sh`

Template (init.sh writes this into `<setup>/<project-name>/ccd-config.sh`, chmod 644 — path is in the setup repo, not in the project folder: the project bind-mount in the CC session is read-write, and if the config lived there CC could rewrite `EXPOSE_GIT_*` itself):

```bash
IMAGE=cc-image-<project-name>          # or cc-image, if no project Dockerfile
CONTAINER_NAME_PREFIX=cc-<project-name>
COMPOSE_NETWORKS=("net1" "net2")        # from Step 1.1; empty array () if none needed
VPN_CONTAINER=cc-<project-name>-vpn     # empty string "", if VPN not needed
VPN_REFCOUNT_FILE="$PROJECT_DIR/.claude/cc-<project-name>-vpn.users"
EXPOSE_GIT_IDENTITY=1   # CC commits as the user (sanitized bind-mount of ~/.gitconfig into /home/claude/.gitconfig:ro)
EXPOSE_GIT_PUSH=0       # =1 — CC pushes via $SSH_AUTH_SOCK (access to every repo in ssh-agent!)
EXPOSE_GITCONFIG=0      # =1 — bind-mount ~/.gitconfig as-is, no sanitization (signingkey, credential.helper, url-rewrites)
```

`$PROJECT_DIR` is set by the `bin/ccd` wrapper BEFORE it sources the config — inside the template this is the literal `$PROJECT_DIR`, not expanded at creation time.

`COMPOSE_NETWORKS` MUST be a **bash array**, not a string — the `ccd` wrapper iterates with `"${COMPOSE_NETWORKS[@]}"`. Empty array `()` = no compose networks attached.

`VPN_CONTAINER=""` (empty string) = VPN logic disabled; the wrapper does not perform any refcount operations.

The full reference table for every `ccd-config.sh` variable (including base ones: `IMAGE`, `COMPOSE_NETWORKS`, `VPN_CONTAINER`, etc.) is in `<setup>/README.md`, section "Project `ccd-config.sh` configuration". Template defaults: `IDENTITY=1, PUSH=0, GITCONFIG=0` — CC commits locally, the user reviews and pushes.

## Step 6. Adapt the project's host-bound scripts (if any from Step 1.2)

For each script:
1. Back up to `<projects-root>/<project-name>/temp-backup/<original-path>` (preserving structure).
2. Move to `<projects-root>/<project-name>/.claude/scripts/<name>.sh`.
3. Replace:
   - `127.0.0.1`/`localhost` for the proxy to a remote host → DNS of the service container (`cc-<project-name>-vpn`, etc.) — resolves over the `cc-net` network.
   - Absolute host paths → paths inside the container, or relative paths.
   - Secret loading: instead of hardcoding — `source "$(dirname "$(realpath "$0")")/../<name>-credentials.env"`.
   - Mutation guards (for DB scripts): grep for forbidden operations (INSERT/UPDATE/DROP/...).
4. **Do NOT manage service container lifecycle** — that is `bin/ccd`'s job via trap+refcount. The script only does `docker start <vpn>` (idempotent, in case of the first call) + `nc -z` readiness wait.
5. `chmod 755`.
6. Update project documentation (CLAUDE.md, README.md, etc.) — replace old paths and instructions with `.claude/scripts/<name>.sh`.

Backing up originals to `temp-backup/` is mandatory BEFORE any change.

## Step 7. Run init.sh

```bash
bash <setup>/<project-name>/init.sh
```
or via the root one:
```bash
bash <setup>/init.sh --project <project-name>
```

Expected: images created, service containers in `Created`, `ccd-config.sh` and `<name>-credentials.env` generated.

## Step 8. Verification

```bash
cd <projects-root>/<project-name> && ccd
```

Inside the CC session:
- `pwd` → `<projects-root>/<project-name>`.
- `id` → `claude:claude` with the host UID/GID.
- Compose services reachable: `nc -zv <service-hostname> <port>` for every network in `COMPOSE_NETWORKS`.
- Adapted scripts work (the actual check is project-specific; e.g. a test SELECT through an adapted db-query.sh).
- `/exit` — the `cc-<project-name>-<pid>` container is removed by `--rm`. Service containers are stopped if refcount is empty.

After verification, the connection is complete. On a new machine the same project is brought up by copying `<setup>/<project-name>/` and running the root `init.sh`.

## Edge cases

- On service-name collisions across projects, the `cc-<project-name>-<service>` convention guarantees isolation. Do NOT reuse service containers from other projects.
- If a project init.sh fails, the root `init.sh` is not blocked — it iterates onward. The final summary will show `[FAIL] project <name>`. The root's exit code becomes non-zero.
- All secrets (xray-config, db-credentials, anything project-specific) are generated ONLY when the file is missing. Never overwritten (see "Do not overwrite" in Step 4). The template (source of truth) lives inside the project init.sh; on field changes, old files are updated by hand after diagnostics.
- `<setup>/<project-name>/` as a whole is excluded from the setup repo. Moving to a new machine — copy it, or connect from scratch using this spec.
- Claude Code OAuth is a separate one-time step **after** the first `ccd` run: the `claude-cc-bin` volume is warmed up by the `ccd` wrapper automatically; on the first start, CC inside the container initiates the OAuth flow.

### Playwright / browser smoke in a cap-drop=ALL container

Verified by end-to-end MCP JSON-RPC handshake on cc-image-wiam (April 2026, `@playwright/mcp` v1.60.0-alpha, chromium-1219). Surprises that cost time:

- `--browser=chromium` is **not** a valid MCP CLI value. Allowed: `chrome, firefox, webkit, msedge`. Chromium is the default — drop the flag.
- `--browser-arg` does **not** exist as a MCP CLI option. Pass chromium command-line flags via `launchOptions.args` in a JSON config referenced by `--config <path>`.
- The chromium `--no-sandbox` flag alone is **not enough** — playwright re-enables sandboxing internally. Use `"chromiumSandbox": false` in `launchOptions` of the `--config` file. The error to watch for is `[FATAL]:zygote_host_impl_linux.cc: No usable sandbox!` followed by SIGTRAP.
- `XDG_CONFIG_HOME`/`XDG_CACHE_HOME` overrides — **don't**. Playwright reads its browser cache via `XDG_CACHE_HOME`; redirecting it hides the bundled chromium and triggers a "Looks like Playwright was just installed or updated" download attempt. The base `cc-image` already pre-creates `~/.config` under `claude:claude` so docker bind-mounts under it (e.g. `~/.config/ccd/mcp.json`) don't escalate the parent dir to root-owned, breaking writability.
- DNS for compose services: any container on a `COMPOSE_NETWORKS` net resolves by its docker name (see `docker network inspect <net>`). Do NOT hardcode IPs — they shift on stack restart. For a host-side `nginx-proxy` reachable in the container only by its docker network IP, use `--host-resolver-rules=MAP *.<tld> <proxy-name>` in chromium args.
- mkcert/local-CA HTTPS — chromium does not trust mkcert's CA in this image. Set `"ignoreHTTPSErrors": true` in `contextOptions` of the `--config` file. Don't rely on `--ignore-https-errors` CLI flag alone — keep it in the config for clarity.

## Reference

`<setup>/lib/project-template/` — an anonymized reference project folder. The project name in the template is `expro` (example project). Contents:

| File | Purpose |
|---|---|
| `init.sh` | full project init.sh example: image `cc-image-expro` (FROM `cc-image`), service `cc-expro-vpn-image` (FROM `debian:bookworm-slim`), copying xray config to `vpn-config/` (chmod 600), generation of `db-credentials.env` and `ccd-config.sh` without overwriting, `docker create` for `cc-expro-vpn`, the flag cascade `--rebuild` / `--rebuild-base-derived` |
| `Dockerfile` | minimal `FROM cc-image` with commented-out extension examples (postgres-client, Playwright). Drop it if the base `cc-image` is enough for the project |
| `Dockerfile.vpn` | service xray + socat. Copied into the project unchanged; all specifics live in `vpn-config/config.json` + `DB_REMOTE_HOST`/`DB_REMOTE_PORT` env vars |
| `vpn-entrypoint.sh` | VPN container entrypoint. Copied unchanged |
| `mcp.json` | empty `{"mcpServers": {}}`. Filled in by hand or generated by the project init.sh |

Reading `init.sh` end-to-end is the fastest way to grasp the layout. Adaptation: copy the whole folder (or the files you need) into `<setup>/<project-name>/`, replace `expro` → `<project-name>` (including the `EXPRO_*` env prefix), adjust `COMPOSE_NETWORKS` and `DB_REMOTE_HOST`, drop the VPN/credentials blocks if not needed.

`vpn-config/config.json` is NOT in the template — it's a secret. Two working paths:
1. **Source of truth in the project**: drop `xray-config.json` into `<projects-root>/<project-name>/xray-config.json` (this is what the template `init.sh` does, section 2). On the first run, `init.sh` will copy it into `<setup>/<project-name>/vpn-config/config.json` (chmod 600). Convenient if the xray config is already in the project repo (with proper `.gitignore`!) or in the user's hands.
2. **Source of truth in the setup folder**: drop `config.json` straight into `<setup>/<project-name>/vpn-config/config.json` by hand (chmod 600). `init.sh` will see the file and skip the copy. Convenient if you want the secret entirely outside the project repo.

In both cases, after the first `init.sh` run, `<setup>/<project-name>/vpn-config/config.json` is the source of truth (and the same file is mounted read-only into the VPN container). Rotation: edit this file + `docker restart cc-<project-name>-vpn`.
