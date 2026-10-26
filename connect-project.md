# Spec: connecting a new project to Claude Code Docker

This document is a task spec for the Claude Code agent. Walk through the steps, analyze the project, agree on architectural decisions with the user, create the artifacts, then verify.

## Infrastructure context

The setup is split into two parts:

**Shared infrastructure** (lives in the setup repo):
- `<setup>/Dockerfile` — `cc-image` (the CC container base image).
- `<setup>/bin/ccd` — wrapper: walks up from `$PWD` to the ancestor that has `<setup>/<basename(ancestor)>/ccd-config.sh`, then launches the CC container for that project. The config lives in the setup repo, not in the project bind-mount (security: otherwise CC could change its own flags from inside the session).
- `<setup>/cc-docker-proxy/haproxy.cfg` — config for the docker-API proxy (`tecnativa/docker-socket-proxy` + a custom deny rule on `/containers/create`); the root `init.sh` brings it up as the `cc-docker-proxy` container in `cc-net`. CC sessions talk to the docker daemon only through it (`DOCKER_HOST=tcp://cc-docker-proxy:2375`).
- `<setup>/lib/init-helpers.sh` — bash helper functions (logging, idempotent docker checks).
- `<setup>/lib/xray-outbound-from-link.py` converts the VPN provider's vless link into the gateway's `outbound.json` (chmod 600).
- `<setup>/lib/api-broker.py` is the API broker that runs inside the gateway container next to xray. It reads the service keys from `/etc/ticket-services/*.env` (the host directory `~/.config/ticket-services/` mounted read-only into the gateway), listens on port 8080, forwards an allow-list of ticket-tracker routes (`/redmine/...`) and code-host routes (`/gitlab/api/v4/...`) upstream with the key attached, and answers 403 to every other path. The keys never enter the session container; the session only knows the broker address from `TICKET_SERVICES_BROKER`.
- `<setup>/init.sh` — root initializer: prerequisites, the shared `cc-net` network, the `claude-auth` volume, the `cc-docker-proxy` container, building `cc-image`, PATH wiring in `~/.bashrc`, the account guard hook in `~/.claude/settings.json`, then iterating `<setup>/*/init.sh`.

**Project settings** (NOT in the setup repo — local to each machine):
- `<setup>/<project-name>/` — settings folder for a specific connected project. Paired with `<projects-root>/<project-name>/` (same name).

The root `init.sh` iterates `<setup>/*/init.sh`. A folder is identified by the presence of `init.sh` inside it. Folders without `init.sh` (`bin/`, `lib/`, `cc-docker-proxy/`) are skipped silently.

**What a session container gets from `bin/ccd`** (the full list; nothing else from the host reaches the session):
- `<projects-root>/<project-name>/` bind-mounted read-write at the same absolute path, which is also the working directory. Inside it, `.git/hooks/` and `.git/config` of every repository found up to depth 4 are re-mounted read-only (`LOCK_GIT_INTERNALS=1`), and `.gitmodules` too when `LOCK_GITMODULES=1`.
- The `claude-auth` volume at `/home/claude/.claude` (OAuth token shared by all projects), or `claude-auth-<account-slug>` when `ccd-config.sh` sets `CLAUDE_ACCOUNT` (the login of that account only), and the `claude-cc-bin` volume read-only at `/opt/claude`.
- The host's `~/.claude/CLAUDE.md`, `settings.json`, `settings.local.json`, `agents/`, `scripts/`, `output-styles/`, `guidelines/`, `skills/` read-only, each only if it exists on the host.
- `<setup>/<project-name>/mcp.json` read-only at `/home/claude/.config/ccd/mcp.json`, passed to CC as `--mcp-config ... --strict-mcp-config`.
- The sanitized `~/.gitconfig` (`EXPOSE_GIT_IDENTITY=1`), an ssh-agent socket at `/ssh-agent` (`EXPOSE_GIT_PUSH=1`), the raw `~/.gitconfig` (`EXPOSE_GITCONFIG=1`), the `-e` variables of `CONTAINER_ENV`.
- `CCD_CLAUDE_ACCOUNT` (the value of `CLAUDE_ACCOUNT`, possibly empty) and `CCD_PROJECT_NAME` as `-e`, plus `<setup>/lib/claude-account.sh` and `<setup>/lib/claude-account-guard.sh` read-only at the same absolute paths: the `UserPromptSubmit` hook from the host `settings.json` that refuses prompts under another login than `CLAUDE_ACCOUNT`.
- `DOCKER_HOST=tcp://cc-docker-proxy:2375`, `host.docker.internal` pointing at the host, the `cc-net` network plus every network of `COMPOSE_NETWORKS`.
- Whatever the user-level hooks `~/.config/ccd/hooks.d/*.sh` (override: `CCD_HOOKS_DIR`) append to `EXTRA_FLAGS`; they are sourced right before `docker run` and are not part of a project.

The host's `~/.ssh/`, `~/.config/` (including `~/.config/ticket-services/`), `~/.aws/` are not visible in the session.

## Conventions

- The name `<setup>/<project-name>/` MUST match the name of `<projects-root>/<project-name>/`. The setup folder name is how the linked project gets located.
- Project image (if `cc-image` needs extending): `cc-image-<project-name>`.
- Project service containers: `cc-<project-name>-<service>` (e.g. `cc-expro-vpn`).
- Service container images: `cc-<project-name>-<service>-image`.

## Inputs

Ask the user for:
1. `<project-name>` — the project folder name (must match the folder in `<projects-root>`).
2. Confirmation that `<projects-root>/<project-name>/` exists and is ready (repo cloned, dependencies installed).
3. The project layout, **internal** or **external** (see Step 3, "Two project layouts"). Internal: the user's own project, the project folder is itself the git repository and `.claude/` is committed in it. External: a workspace over one or more repositories that belong to someone else; `.claude/` lives in the workspace outside every repository. The answer decides where local files go and whether any `.gitignore` is touched.

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
If scripts or configs reference an external host via `127.0.0.1:<port>` (the typical sign of an SSH tunnel or socat relay on the host), or corporate hosts (git, tracker, DB) are reachable only through a VPN — **a service gateway container is needed** in the shared `cc-net` network. Container name: `cc-<project-name>-vpn`. Implementation: xray (`<setup>/lib/project-template/Dockerfile.vpn`, which also carries the API broker of Step 1.3a; a gateway without the broker drops the `python3`, `COPY` and `ENTRYPOINT` lines and runs `xray run` directly) that reads three config files from `vpn-config/`: `outbound.json` (the secret VPN outbound, generated from the provider's vless link by `<setup>/lib/xray-outbound-from-link.py`), `routing.json` (which domains/IPs go through the VPN; everything else goes direct; corporate rules point to a `corp` freedom outbound chained through `vpn` via `proxySettings`, so hostnames are resolved locally over DoH and the VPN server receives IPs) and `inbounds-container.json` (what the gateway listens on: SOCKS/HTTP proxies on 10808/10809, `dokodemo-door` port forwards to DB hosts, and the ssh and 443 ports forwarded to the corporate git host with TLS sniffing; the ssh forward uses the host's real ssh port, 22 in the template, e.g. 10022 when the corporate GitLab serves ssh there). The container gets `--network-alias <corporate-host>` for every corporate hostname, so session containers resolve e.g. `git.example.com` to the gateway over Docker DNS and need no proxy settings at all: only corporate destinations go through the VPN, everything else (Claude API, package registries) goes direct. The same `outbound.json` + `routing.json` with `inbounds-host.json` serve the host (systemd user service), so Chrome, PhpStorm and the console share one routing policy. Examples: `<setup>/lib/project-template/vpn-config/`.

Git over ssh to a corporate host needs its host key in the image: the base `cc-image` pre-seeds `known_hosts` only for github.com, gitlab.com and bitbucket.org, and a non-interactive session cannot answer the host-key prompt. Put the `ssh-keyscan -p <port> <host>` output into `<setup>/<project-name>/ssh-known-hosts` (one line per host, the `[host]:port` form when the port is not 22) and let the project `Dockerfile` append it to `/home/claude/.ssh/known_hosts` (`COPY --chown=claude:claude ssh-known-hosts /tmp/ssh-known-hosts` + `RUN cat ... >> /home/claude/.ssh/known_hosts`).

### 1.3a. Ticket tracker and code host API through the gateway
If the session has to call a ticket tracker or a code-host API (merge requests, issue updates: the pipeline scripts in `~/.claude/scripts/` do this when the project has `.claude/ticket-services.json`), the API keys stay outside the session container. The gateway container runs `lib/api-broker.py` next to xray; the session reaches it as `TICKET_SERVICES_BROKER=http://cc-<project-name>-vpn:8080` and never sees the keys. What this needs:
- `~/.config/ticket-services/<project-name>.env` on the host (directory 700, file 600): `TICKETHOST_API_KEY`, `CODEHOST_TOKEN`, and for hosts behind the VPN also `HTTPS_PROXY` (the host-side xray HTTP inbound, used by host-side runs of the same scripts), `TICKETHOST_URL`, `CODEHOST_URL`, `CODEHOST_PROJECT` (the broker builds its allow-list from the last three). The project `init.sh` checks that the file holds non-empty `TICKETHOST_API_KEY` and `CODEHOST_TOKEN` and reports what to fill in; it never creates the file. The broker reads every `*.env` in the directory, so the gateway of one project also sees the files of the others.
- The whole directory mounted read-only into the gateway: `-v "$HOME/.config/ticket-services:/etc/ticket-services:ro"` in `VPN_CREATE_ARGS`.
- `CONTAINER_ENV=("TICKET_SERVICES_BROKER=http://cc-<project-name>-vpn:8080")` in `ccd-config.sh`.
- A project `Dockerfile.vpn` that installs `python3`, copies `lib/api-broker.py` and a `vpn-entrypoint.sh` starting xray and the broker in the background (`wait -n`, so the exit of either one stops the container; the broker goes upstream through the xray HTTP inbound `http://127.0.0.1:10809`). Because it copies from `lib/`, the image is built with the setup root as the build context: `docker build -t cc-<project-name>-vpn-image -f "$SCRIPT_DIR/Dockerfile.vpn" "$SCRIPT_DIR/.."`.

### 1.3b. Service secrets: issuing, checking, rotating
The file `~/.config/ticket-services/<project-name>.env` (directory 700, file 600) is named after the project folder. Lines: `TICKETHOST_API_KEY`, `CODEHOST_TOKEN`; for services behind the VPN also `HTTPS_PROXY`, `TICKETHOST_URL`, `CODEHOST_URL`, `CODEHOST_PROJECT`. The session container never sees the keys: the directory is mounted read-only into the gateway and the broker adds them to the requests; host-side runs of the scripts read the file directly. Two projects of one company hold the same key and token, each in its own file.

**Redmine API key.**
- Where: `<tracker-url>/my/account`, the «API access key» block on the right, «Show». Rotation: «Reset» on the same page, then the new value into every file of that tracker.
- What it is: the personal key of the user; it carries no rights of its own, it grants everything its owner may do in every project.
- Server setting: «Administration, Settings, API», REST web service enabled. Without it every request is 403.
- Rights of the user's role in the project: view issues (the ticket with journal, relations and attachments, the list of own open issues), edit issues (notes, status and assignee go in one request; «add notes» alone is not enough), the role's workflow transitions between the statuses of `allowed_statuses` and `moments` in `ticket-services.json` (else 422), and the reviewer of `moments.publish.assignee` in a role that can be assigned issues.
- No administrator needed. Listing users by login is admin-only, so people in the config are ids, taken from the «Создана:» and «Назначена:» lines of a fetched ticket. Custom field names are admin-only too; without them the journal shows «поле N».
- Through the broker: ticket and attachments, own issues, statuses, current user, custom fields, issue update. Everything else 403.

**GitLab token.**
- Where: `<gitlab-url>/-/user_settings/personal_access_tokens`, **Legacy token** (fine-grained tokens in this version bind to projects and resources, with no gain), name `ticket-services`, scope `api` only, expiry at will. Rotation: revoke the old one, issue a new one with the same parameters, write it into the files of every project on that GitLab.
- Why `api`: creating a merge request works only with it; reading requests and looking up a user are included. `write_repository` is not needed: fetch and push go over ssh. It is needed only by a project without `codehost.git_url`, where the script pushes over https with the token.
- Project role: Developer. The token grants nothing beyond the role. A bot token and a deploy key can only be created by a Maintainer, hence the personal token and the personal ssh key.
- Project settings: the base branch protected on the server (a Developer cannot push to it, merge goes through the request); `codehost.reviewer` is a login resolved through `/users?username=`; deleting the source branch after merge is a flag of the request, no project setting.
- Through the broker: list and create merge requests, update the description, look up a user by login, server version. Everything else 403.

**Ssh key for git from the container.**
- Issue: `ssh-keygen -t ed25519 -N '' -C ccd-<project-name> -f ~/.ssh/id_ed25519_ccd_<project-name>`; the public part into GitLab, «User settings, SSH Keys», usage type Authentication. The path goes into `SSH_AGENT_KEY` of the project's `ccd-config.sh` with `EXPOSE_GIT_PUSH=1`.
- The container gets a separate ccd agent holding only this key. Rotation: a new key, replace it in GitLab and in `SSH_AGENT_KEY`, delete the old one from GitLab.
- The host key of GitLab in the image: Step 1.3, `ssh-known-hosts`, the port from `codehost.git_url`.

**GitHub token.**
- `https://github.com/settings/personal-access-tokens/new`, fine-grained, on the project's repositories, permissions Contents read and write, Pull requests read and write, Administration read and write (turning on branch deletion after merge, a repository setting). The value goes into `CODEHOST_TOKEN` of the project's file.

**Check after issuing.** From the project root on the host (for services behind the VPN from the session container, the host cannot reach them):

```bash
python3 - <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
from ticket_services import config as configuration, tickethost
config = configuration.load(Path.cwd())
host = tickethost.make(config)
print('пользователь:', host.current_user().name)
print('статусы:', ', '.join(sorted(host.load_statuses())))
PY
```

It prints the key owner's name and the server's statuses; every status of `allowed_statuses` and `moments` must be in the list. GitLab: `curl -s -o /dev/null -w '%{http_code}\n' -H "PRIVATE-TOKEN: $(sed -n 's/^CODEHOST_TOKEN=//p' ~/.config/ticket-services/<project-name>.env)" <gitlab-url>/api/v4/user` prints 200. The broker from the container: `curl -s $TICKET_SERVICES_BROKER/redmine/users/current.json`. Ssh from the container: `git ls-remote <codehost.git_url> HEAD`. The whole path live: fetch a ticket that already sits in `moments.take.status`, so its status does not change: `python3 ~/.claude/scripts/ticket-fetch.py <number>`.

### 1.4. System requirements
The base `cc-image` already carries document conversion for `~/.claude/scripts/pipeline-sources.sh` (`pdftotext`, `soffice`, `python3` + `openpyxl`). Do not re-install it per project. It also sets `LANG=C.UTF-8`: without a UTF-8 locale `soffice --convert-to txt:Text` replaces every non-ASCII character with `?`, so a Cyrillic docx converts to garbage. Do not unset or override `LANG` in a project Dockerfile.

What the project uses that is not in the base `cc-image`:
- Playwright/Cypress — browser libs + Chromium. Under `--cap-drop=ALL` (the ccd default) chromium fails to set up its sandbox: launch with `chromiumSandbox: false` in `launchOptions` of the playwright `--config` file. Do NOT pass `--browser=chromium` (not a valid MCP CLI value — chromium is the default) and do NOT use `--browser-arg` (does not exist). For dev domains pointing at a host-side nginx-proxy (typical `127.0.0.1 *.lc` in host `/etc/hosts`, absent in the container), pass `--host-resolver-rules=MAP *.<tld> <proxy-service-name>` via `launchOptions.args`. Dockerfile example: `<setup>/lib/project-template/Dockerfile`, `mcp.json` and `playwright-mcp-config.json` snippets: README § MCP servers.
- Chrome DevTools MCP (`chrome-devtools-mcp`) — device emulation, throttling, performance traces, Lighthouse. Needs a real Chrome: install `google-chrome-stable` from the Google apt repo in the project Dockerfile; the server launches it by channel `stable`, the Playwright Chromium is not picked up. Under `--cap-drop=ALL` pass `--chrome-arg=--no-sandbox --chrome-arg=--disable-setuid-sandbox --chrome-arg=--disable-dev-shm-usage`. Dockerfile example: `<setup>/lib/project-template/Dockerfile`, `mcp.json` snippet: README § MCP servers.
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
| API broker in the gateway (`~/.config/ticket-services/<project-name>.env`, the read-only mount, `CONTAINER_ENV`, broker-enabled `Dockerfile.vpn`) | Step 1.3a: the session calls a ticket tracker or code-host API |
| `ssh-known-hosts` appended into the project image | Step 1.3: git over ssh to a host other than github.com / gitlab.com / bitbucket.org |
| `EXPOSE_GIT_PUSH=1` with `SSH_AGENT_KEY` | CC must push itself (the pipeline publishes merge requests). Name the one deploy key for this project; without `SSH_AGENT_KEY` the session gets the user's whole ssh-agent |
| Non-empty `COMPOSE_NETWORKS` | Step 1.1 found compose networks CC must attach to |
| Adapt scripts in `.claude/scripts/` | Step 1.2 found host-bound scripts that should run from the CC container |
| `<projects-root>/<project-name>/.claude/<name>-credentials.env` | The project has passwords/keys the scripts need |
| `CLAUDE_ACCOUNT="<email>"` in `ccd-config.sh` | The project runs on its own claude.ai subscription, not the shared login. Procedure: `<setup>/project-account.md` |

If nothing beyond the base is needed, `<setup>/<project-name>/` only contains a minimal `init.sh` that generates `ccd-config.sh` (with empty `COMPOSE_NETWORKS=()` and empty `VPN_CONTAINER`) and an empty `mcp.json`.

**Do not act blindly**: at every decision, explicitly show the user what you found in Step 1, what you propose to do, and wait for confirmation.

## Step 3. Create the folder structure

Inside `<setup>/<project-name>/`:
```
init.sh                         # required
ccd-config.sh                   # generated by init.sh; the wrapper config lives in the setup repo, not in the project bind-mount — otherwise CC from a session could rewrite its own EXPOSE_GIT_* flags
[ccd-pre-start.sh]              # optional; sourced by ccd before session launch — service container validation, config-hash checks
mcp.json                        # generated empty by init.sh; project-level MCP servers. Source of truth lives here, not in <projects-root>/.../.mcp.json (read-only bind-mount + --strict-mcp-config in ccd → anti-tampering)
[Dockerfile]                    # optional
[ssh-known-hosts]               # optional; host keys of corporate git hosts, appended into the image by Dockerfile (Step 1.3)
[Dockerfile.vpn]                # optional; the xray gateway, plus the API broker when Step 1.3a applies
[vpn-entrypoint.sh]             # optional; only with the API broker: starts xray and api-broker.py together
[vpn-config/]                   # optional; outbound.json (secret), routing.json, inbounds-*.json. May live outside the setup repo (~/.config/xray-<project-name>/), see Reference
[Dockerfile.<svc>]              # optional
[<svc>-entrypoint.sh]           # optional
[<svc>-config/]                 # optional (secrets inside)
```

Inside `<projects-root>/<project-name>/.claude/`:
```
[<name>-credentials.env]        # generated by init.sh, chmod 600
[<mcp-server>-config.json]      # generated by init.sh, per-MCP-server config (e.g. playwright-mcp-config.json) — referenced from mcp.json by absolute path
[cc-<project-name>-vpn.users]   # VPN refcount file plus its .lock, written by ccd when VPN_REFCOUNT_FILE points here (the template default)
[scripts/]                      # adapted scripts, if any
```

At the project root, next to `.claude/`: `.playwright-mcp/` (Playwright MCP output dir, created by the server) and `.chrome-devtools-mcp/` (Chrome DevTools MCP filesystem root, created by the project `init.sh`, Step 4 item 7.2).

On the host, outside both folders: `~/.config/ticket-services/<project-name>.env` (Step 1.3a; filled in by the user by hand, the values per Step 1.3b) and, optionally, `~/.config/xray-<project-name>/` for the VPN config shared with the host xray service.

`bin/ccd` only bind-mounts `<setup>/<project-name>/mcp.json` from the setup folder into the container (read-only, at `/home/claude/.config/ccd/mcp.json`). Anything else an MCP server needs (its own `--config <path>` file) lives in `<projects-root>/<project-name>/.claude/` — it is visible to the container through the project bind-mount, and `mcp.json` references it by absolute path.

`<setup>/<project-name>/` is excluded from the setup repo whitelist as a whole — secrets inside are safe.

### Two project layouts

The local files above (`*-credentials.env`, `<mcp-server>-config.json`, `*.users` and `*.users.lock`, `.playwright-mcp/`, `.chrome-devtools-mcp/`) must never be committed. Where they sit and who ignores them depends on the layout the user chose in Inputs:

- **Internal project** (the user's own, started from scratch): `<projects-root>/<project-name>/` is itself the git repository and `.claude/` is committed in it. Its `.gitignore` MUST ignore `.claude/*-credentials.env`, `.claude/*-config.json` of MCP servers, `.claude/*.users`, `.claude/*.users.lock`, `.playwright-mcp/`, `.chrome-devtools-mcp/`. Add the missing entries as part of the connection and tell the user. The project init.sh, when generating the credentials file, **MUST emit a warning** that ignoring it is the project `.gitignore`'s job.
- **External project** (repositories owned by someone else): `<projects-root>/<project-name>/` is a workspace folder, not a repository; the repositories are cloned inside it and `.claude/` lies in the workspace outside every repository, so nothing local can reach a repository. Nothing is added to those repositories: no files, no `.gitignore` edits. If a local file would have to sit inside a repository (an MCP output dir, a refcount file), move it to the workspace or to the host (`VPN_REFCOUNT_FILE="$HOME/.cache/ccd/cc-<project-name>-vpn.users"`) instead. `LOCK_GIT_INTERNALS` still covers every repository of the workspace: `ccd` finds `.git` directories up to depth 4 below the workspace root.

## Step 4. Implement `<setup>/<project-name>/init.sh`

A full working example with a VPN container is `<setup>/lib/project-template/init.sh`. The project name in the template is `expro` (example project); when adapting, replace `expro` with `<project-name>`, `EXPRO_*` variables with `<PROJECT_NAME>_*`, adjust `COMPOSE_NETWORKS`, the hosts in `vpn-config/` and the `--network-alias` list, drop the VPN/credentials blocks if the project does not need them. The template's neighboring files (`Dockerfile`, `Dockerfile.vpn`, `vpn-config/`, `mcp.json`) are copied into `<setup>/<project-name>/` as needed — see Step 3.

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

# 2. Check that vpn-config/outbound.json exists (cc_die with the xray-outbound-from-link.py command if not); never generate it
# 3. Build cc-image-<project-name> (if a Dockerfile exists, FROM cc-image)
# 4. Build cc-<project-name>-<svc>-image (if a Dockerfile.<svc> exists, may be FROM any base;
#    with the API broker the build context is the setup root, "$SCRIPT_DIR/..", because Dockerfile.vpn copies lib/api-broker.py)
# 5. Generate <name>-credentials.env (chmod 600) — only if the file is missing, otherwise SKIP
# 5a. Check ~/.config/ticket-services/<project-name>.env (projects with the API broker): SKIP when it holds non-empty
#     TICKETHOST_API_KEY and CODEHOST_TOKEN, otherwise cc_log_info naming the keys to fill in by hand
#     (TICKETHOST_API_KEY, CODEHOST_TOKEN, HTTPS_PROXY, TICKETHOST_URL, CODEHOST_URL, CODEHOST_PROJECT; directory 700, file 600).
#     Never create or write the file.
# 6. Generate ccd-config.sh (with VPN_IMAGE/VPN_CREATE_ARGS/CONTAINER_ENV if VPN needed) — only if missing, otherwise SKIP with a missing-fields check
# 6.1. Copy ccd-pre-start.sh from template — only if the file is missing (projects with VPN)
# 7. Generate mcp.json (empty `{"mcpServers": {}}`) — only if the file is missing, otherwise SKIP
# 7.1. Generate per-MCP-server configs in $PROJECT_DIR/.claude/<server>-config.json — only if missing,
#      otherwise SKIP (same idempotency contract). Referenced from mcp.json by absolute path.
#      Example content: README § MCP servers (playwright-mcp-config.json).
# 7.2. mkdir -p $PROJECT_DIR/.chrome-devtools-mcp (projects with Chrome DevTools MCP: the --filesystem-root must exist
#      before the server starts); SKIP when present
# 8. Create service containers (config-hash based: source ccd-config.sh, compare hash of VPN_CREATE_ARGS
#    against ccd.config-hash label on the container, recreate on mismatch)

cc_log_ok "$PROJECT_NAME/init.sh: ok"
```

### Idempotency
Every resource — `inspect → SKIP / create`. No unconditional actions that would clobber existing state.

### Do not overwrite existing configs
`ccd-config.sh` and `<name>-credentials.env` are written ONLY when missing. If the file exists, compare its set of required keys against the template inside init.sh; on mismatch, emit `cc_log_info` with diagnostics and the user updates by hand. `~/.config/ticket-services/<project-name>.env` and `vpn-config/outbound.json` are never written by init.sh at all, only checked.

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
CLAUDE_ACCOUNT=""        # email of the claude.ai account whose subscription the project uses; "" = the shared login (README, Per-project Claude account)
COMPOSE_NETWORKS=("net1" "net2")        # from Step 1.1; empty array () if none needed
VPN_CONTAINER=cc-<project-name>-vpn     # empty string "", if VPN not needed
VPN_REFCOUNT_FILE="$PROJECT_DIR/.claude/cc-<project-name>-vpn.users"
VPN_IMAGE=cc-<project-name>-vpn-image  # required for config-hash auto-recreation in ccd-pre-start.sh
VPN_CREATE_ARGS=(                      # extra docker create args for the gateway container
    --network-alias git.example.com    # one alias per corporate hostname the gateway serves
    -v "$SETUP_DIR/$PROJECT_NAME/vpn-config:/etc/xray:ro"
    -v "$HOME/.config/ticket-services:/etc/ticket-services:ro"   # only with the API broker (Step 1.3a)
)
CONTAINER_ENV=("TICKET_SERVICES_BROKER=http://cc-<project-name>-vpn:8080")   # only with the API broker; empty () otherwise
EXPOSE_GIT_IDENTITY=1   # CC commits as the user (sanitized bind-mount of ~/.gitconfig into /home/claude/.gitconfig:ro)
EXPOSE_GIT_PUSH=0       # =1: CC pushes over ssh-agent, the dedicated agent with SSH_AGENT_KEY, or the user's whole $SSH_AUTH_SOCK without it
SSH_AGENT_KEY=""        # private key file for the dedicated ccd agent, e.g. "$HOME/.ssh/<project-name>-deploy"; used only with EXPOSE_GIT_PUSH=1
EXPOSE_GITCONFIG=0      # =1 — bind-mount ~/.gitconfig as-is, no sanitization (signingkey, credential.helper, url-rewrites)
LOCK_GIT_INTERNALS=1    # .git/hooks and .git/config of every repo (depth 4) mounted :ro; =0 reopens git-RCE vectors
LOCK_GITMODULES=0       # =1: .gitmodules mounted :ro (blocks git submodule add from the session)
```

`$PROJECT_DIR` is set by the `bin/ccd` wrapper BEFORE it sources the config — inside the template this is the literal `$PROJECT_DIR`, not expanded at creation time. `$SETUP_DIR`, `$PROJECT_NAME` and `$HOME` are available the same way.

`COMPOSE_NETWORKS` MUST be a **bash array**, not a string — the `ccd` wrapper iterates with `"${COMPOSE_NETWORKS[@]}"`. Empty array `()` = no compose networks attached. `VPN_CREATE_ARGS` and `CONTAINER_ENV` are bash arrays too.

`VPN_CONTAINER=""` (empty string) = VPN logic disabled; the wrapper does not perform any refcount operations.

`VPN_REFCOUNT_FILE`: `ccd` creates its directory and the file on first use and keeps a `<file>.lock` next to it. The template default `$PROJECT_DIR/.claude/cc-<project-name>-vpn.users` is for the internal layout; for an external project, or when two projects share one gateway, use `"$HOME/.cache/ccd/cc-<project-name>-vpn.users"` (then all sharing projects point at the same file, otherwise one project stops the gateway under the other).

Variables not in the README table:

| Variable | Type | Purpose |
|---|---|---|
| `CONTAINER_ENV` | bash array | `NAME=value` strings, each passed to `docker run` as `-e`. Used for `TICKET_SERVICES_BROKER`. Default `()`. |
| `SSH_AGENT_KEY` | path | With `EXPOSE_GIT_PUSH=1`: `ccd` starts (or reuses) its own ssh-agent at `${XDG_RUNTIME_DIR:-/tmp}/ccd-agent-<project-name>.sock`, loads this one key into it (a passphrase is asked once, the agent outlives the session) and mounts that socket as `/ssh-agent`. The user's own agent with every other key is never exposed. `ccd` exits with an error when the file is missing. Unset: the host `$SSH_AUTH_SOCK` is mounted as before. |

The reference table for `IMAGE`, `COMPOSE_NETWORKS`, `VPN_*`, `EXPOSE_GIT_*`, `LOCK_GIT_INTERNALS`, `LOCK_GITMODULES` is in `<setup>/README.md`, section "Project `ccd-config.sh` configuration". Template defaults: `IDENTITY=1, PUSH=0, GITCONFIG=0, LOCK_GIT_INTERNALS=1, LOCK_GITMODULES=0` — CC commits locally, the user reviews and pushes. Unset `EXPOSE_*` reads as `0`, unset `LOCK_GIT_INTERNALS` as `1`.

## Step 6. Adapt the project's host-bound scripts (if any from Step 1.2)

For each script:
1. Back up to `<projects-root>/<project-name>/temp-backup/<original-path>` (preserving structure).
2. Move to `<projects-root>/<project-name>/.claude/scripts/<name>.sh`.
3. Replace:
   - `127.0.0.1`/`localhost` for the proxy to a remote host → DNS of the service container (`cc-<project-name>-vpn`, etc.) — resolves over the `cc-net` network.
   - Absolute host paths → paths inside the container, or relative paths.
   - Secret loading: instead of hardcoding — `source "$(dirname "$(realpath "$0")")/../<name>-credentials.env"`.
   - Mutation guards (for DB scripts): grep for forbidden operations (INSERT/UPDATE/DROP/...).
4. **Do NOT manage service container lifecycle** — that is `bin/ccd`'s job via trap+refcount. The script only does `docker start <vpn>` (idempotent, in case of the first call) + `nc -z` readiness wait. Git, curl and other clients talking to a corporate hostname need nothing: the gateway's `--network-alias` makes the hostname resolve to it.
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

Expected: images created, service containers in `Created`, `ccd-config.sh`, `mcp.json`, `<name>-credentials.env` and the per-MCP-server configs generated, `.chrome-devtools-mcp/` created when the server is configured. With the API broker, the `[..]` line about `~/.config/ticket-services/<project-name>.env` disappears once the user has filled the file in.

## Step 8. Verification

```bash
cd <projects-root>/<project-name> && ccd
```

Inside the CC session:
- `pwd` → `<projects-root>/<project-name>`.
- `id` → `claude:claude` with the host UID/GID.
- Compose services reachable: `nc -zv <service-hostname> <port>` for every network in `COMPOSE_NETWORKS`.
- `/mcp` lists exactly the servers of `<setup>/<project-name>/mcp.json`; a browser server answers a trivial call (navigate to the app URL).
- With a gateway: `nc -zv cc-<project-name>-vpn <forwarded-port>` and `getent hosts <corporate-host>` resolve to the gateway. With the API broker: `curl -s "$TICKET_SERVICES_BROKER/gitlab/api/v4/version"` returns JSON, `curl -s -o /dev/null -w '%{http_code}' "$TICKET_SERVICES_BROKER/gitlab/api/v4/user"` returns 403 (not in the allow-list).
- With `EXPOSE_GIT_PUSH=1` and `SSH_AGENT_KEY`: `ssh-add -l` shows that one key and nothing else; `git ls-remote <corporate-ssh-url>` works without a host-key prompt (the `ssh-known-hosts` line is in the image).
- Adapted scripts work (the actual check is project-specific; e.g. a test SELECT through an adapted db-query.sh).
- `/exit` — the `cc-<project-name>-<pid>` container is removed by `--rm`. Service containers are stopped if refcount is empty. No `ccd: WARNING` line about changed git internals on stderr (the audit of `.git/hooks`, `.git/config`, `.gitattributes`, `.gitmodules` that `ccd` runs at cleanup).

After verification, the connection is complete. On a new machine the same project is brought up by copying `<setup>/<project-name>/` and running the root `init.sh`.

## Edge cases

- On service-name collisions across projects, the `cc-<project-name>-<service>` convention guarantees isolation. Do NOT reuse service containers from other projects, with one exception: several projects of the same corporate network may share one gateway (`VPN_CONTAINER=cc-<first-project>-vpn`) only when `VPN_CONTAINER`, `VPN_IMAGE`, `VPN_CREATE_ARGS` and `VPN_REFCOUNT_FILE` are identical in every sharing `ccd-config.sh` and the refcount file lives on the host (`$HOME/.cache/ccd/`). The config hash in `ccd-pre-start.sh` is computed from `VPN_CREATE_ARGS`: any difference between the projects recreates the gateway on every switch between them.
- The dedicated ssh-agent of `SSH_AGENT_KEY` is per project (`ccd-agent-<project-name>.sock`) and is not stopped by `ccd`; `ssh-add -D` against that socket, or removing the socket, drops the key from memory.
- If a project init.sh fails, the root `init.sh` is not blocked — it iterates onward. The final summary will show `[FAIL] project <name>`. The root's exit code becomes non-zero.
- All secrets (vpn-config/outbound.json, db-credentials, anything project-specific) are generated ONLY when the file is missing. Never overwritten (see "Do not overwrite" in Step 4). The template (source of truth) lives inside the project init.sh; on field changes, old files are updated by hand after diagnostics.
- `<setup>/<project-name>/` as a whole is excluded from the setup repo. Moving to a new machine — copy it, or connect from scratch using this spec.
- Claude Code OAuth is a separate one-time step **after** the first `ccd` run: the `claude-cc-bin` volume is warmed up by the `ccd` wrapper automatically; on the first start, CC inside the container initiates the OAuth flow. With `CLAUDE_ACCOUNT` set, the step repeats once in the project's own `claude-auth-<account-slug>` volume and the user must sign in with exactly that account; the guard hook refuses prompts under any other login.

### Playwright / browser smoke in a cap-drop=ALL container

Verified by end-to-end MCP JSON-RPC handshake on a project image (April 2026, `@playwright/mcp` v1.60.0-alpha, chromium-1219). Surprises that cost time:

- `--browser=chromium` is **not** a valid MCP CLI value. Allowed: `chrome, firefox, webkit, msedge`. Chromium is the default — drop the flag.
- `--browser-arg` does **not** exist as a MCP CLI option. Pass chromium command-line flags via `launchOptions.args` in a JSON config referenced by `--config <path>`.
- The chromium `--no-sandbox` flag alone is **not enough** — playwright re-enables sandboxing internally. Use `"chromiumSandbox": false` in `launchOptions` of the `--config` file. The error to watch for is `[FATAL]:zygote_host_impl_linux.cc: No usable sandbox!` followed by SIGTRAP.
- `XDG_CONFIG_HOME`/`XDG_CACHE_HOME` overrides — **don't**. Playwright reads its browser cache via `XDG_CACHE_HOME`; redirecting it hides the bundled chromium and triggers a "Looks like Playwright was just installed or updated" download attempt. The base `cc-image` already pre-creates `~/.config` under `claude:claude` so docker bind-mounts under it (e.g. `~/.config/ccd/mcp.json`) don't escalate the parent dir to root-owned, breaking writability.
- DNS for compose services: any container on a `COMPOSE_NETWORKS` net resolves by its docker name (see `docker network inspect <net>`). Do NOT hardcode IPs — they shift on stack restart. For a host-side `nginx-proxy` reachable in the container only by its docker network IP, use `--host-resolver-rules=MAP *.<tld> <proxy-name>` in chromium args.
- mkcert/local-CA HTTPS — chromium does not trust mkcert's CA in this image. Set `"ignoreHTTPSErrors": true` in `contextOptions` of the `--config` file. Don't rely on `--ignore-https-errors` CLI flag alone — keep it in the config for clarity.
- **MCP command: the baked binary, never `npx ...@latest`.** In `mcp.json` set `"command": "/usr/local/bin/playwright-mcp"` (the global bin installed in the image). `npx @playwright/mcp@latest` re-resolves to the newest release at every launch, and its bundled playwright wants a Chromium revision the image never installed (`playwright install chromium` ran for the build-time version only), so every browser call fails with `"browser is not installed"`. The binary is identical to the baked `@playwright/mcp` and its Chromium, needs no network, and tracks the image on every rebuild. This was the real cause of "ccd can't see the browser": the image was correct, the runtime command was pulling a mismatched version.

### Chrome DevTools MCP in a cap-drop=ALL container

Verified by end-to-end MCP JSON-RPC handshake on a project image (October 2026, `chrome-devtools-mcp` 1.10.1, Google Chrome 155): `new_page`, `emulate` with `390x844x3,mobile,touch` + `Fast 4G` + 4x CPU, `take_screenshot`, `lighthouse_audit` in navigation mode, `performance_start_trace`. What matters:

- **Browser resolution.** Without `--executablePath` the server calls puppeteer with `channel: 'chrome'`, which resolves only a system Google Chrome (`/opt/google/chrome/chrome`). The Playwright Chromium in `~/.cache/ms-playwright` is never considered, and `PUPPETEER_EXECUTABLE_PATH` is ignored because the channel is set. Install `google-chrome-stable` from `https://dl.google.com/linux/chrome/deb/` (amd64 only); it tracks the current stable on every rebuild, which is what the server requires.
- **Sandbox.** Puppeteer does not add `--no-sandbox` by itself. Pass `--chrome-arg=--no-sandbox` and `--chrome-arg=--disable-setuid-sandbox` (the `--chrome-arg=<flag>` form, one flag per argument). Add `--chrome-arg=--disable-dev-shm-usage`: docker's 64 MB `/dev/shm` crashes tabs on heavy pages.
- **Baked binary, same rule as Playwright.** `"command": "/usr/local/bin/chrome-devtools-mcp"`, never `npx chrome-devtools-mcp@latest`: a newer server may need a newer Chrome than the image holds, and `npx` adds a network round-trip on every start.
- **Filesystem root.** `--filesystem-root <projects-root>/<project>/.chrome-devtools-mcp` limits where `filePath` arguments may write. The directory must exist at server start (realpath is resolved once), so the project `init.sh` creates it (Step 4, item 7.2); in the internal layout it is ignored by the project `.gitignore` next to `.playwright-mcp`, in the external layout it lies in the workspace (Step 3, "Two project layouts").
- **Config discovery.** The server auto-loads `cd4a.config.json` from the working directory (the project root inside the container) unless `CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY=1` is set in `env`. Set it: a config planted in the repo could otherwise add `chromeArg`, `proxyServer` or `executablePath`.
- **Telemetry off.** `--no-usage-statistics` and `--no-performance-crux` (trace URLs would otherwise be sent to Google's CrUX API), `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1`.
- **Reaching the app.** The CC container is on `COMPOSE_NETWORKS`, so the app is `http://<compose-service-container>/`, or `http://host.docker.internal:<host-port>/` through the published port. `localhost:<port>` from the project README is the host's address and does not resolve inside the container.

## Reference

`<setup>/lib/project-template/` — an anonymized reference project folder. The project name in the template is `expro` (example project). Contents:

| File | Purpose |
|---|---|
| `init.sh` | full project init.sh example: image `cc-image-expro` (FROM `cc-image`), service `cc-expro-vpn-image` (FROM `debian:bookworm-slim`), check that `vpn-config/outbound.json` exists, generation of `db-credentials.env` and `ccd-config.sh` without overwriting, config-hash based `docker create` for `cc-expro-vpn`, the flag cascade `--rebuild` / `--rebuild-base-derived` |
| `ccd-pre-start.sh` | pre-start hook: validates VPN container config hash, recreates on drift. Sourced by `ccd` before every session launch |
| `Dockerfile` | minimal `FROM cc-image` with commented-out extension examples (postgres-client, Playwright). Drop it if the base `cc-image` is enough for the project |
| `Dockerfile.vpn` | gateway: xray reading `/etc/xray/{outbound,routing,inbounds-container}.json` plus the API broker (Step 1.3a): `python3`, `COPY lib/api-broker.py`, `COPY expro/vpn-entrypoint.sh` and that entrypoint, so it is built from the setup root. Copied into the project with `expro` replaced by `<project-name>`; all other specifics live in `vpn-config/`. A gateway without the broker drops the broker lines and runs `xray run` directly. Keep `XRAY_VERSION` at v26.3.27 or newer: the chained `corp` outbound breaks HTTPS on 25.x |
| `vpn-entrypoint.sh` | gateway entrypoint: xray and `api-broker.py` in the background, `wait -n` so the exit of either stops the container; copied into the project as is |
| `vpn-config/` | anonymized `routing.json`, `inbounds-host.json`, `inbounds-container.json`. `outbound.json` is a secret and is not in the template |
| `mcp.json` | empty `{"mcpServers": {}}`. Filled in by hand or generated by the project init.sh |

Reading `init.sh` end-to-end is the fastest way to grasp the layout. Adaptation: copy the whole folder (or the files you need) into `<setup>/<project-name>/`, replace `expro` → `<project-name>` (including the `EXPRO_*` env prefix), adjust `COMPOSE_NETWORKS`, the hosts in `vpn-config/` and the `--network-alias` list, drop the VPN/credentials blocks if not needed.

`vpn-config/outbound.json` is NOT in the template — it's a secret. Generate it from the provider's vless link: `python3 <setup>/lib/xray-outbound-from-link.py '<vless://...>' <setup>/<project-name>/vpn-config/outbound.json` (chmod 600 is applied by the script). `init.sh` only checks that the file exists. One folder is the single source of truth for both the host xray service and the gateway container (mounted read-only via `VPN_CREATE_ARGS`): `<setup>/<project-name>/vpn-config/` by default, or a folder outside the setup repo such as `~/.config/xray-<project-name>/` when the host service must keep working without the setup repo (then point both the systemd unit and the `-v` mount there and adjust the `init.sh` check). Rotation: regenerate `outbound.json` + `docker restart cc-<project-name>-vpn` + restart the host xray service. Adding a corporate host: `routing.json` rule, `--network-alias` in `VPN_CREATE_ARGS` (the config hash recreates the container on the next `ccd`), and a forward in `inbounds-container.json` if the port is not 22/443.
