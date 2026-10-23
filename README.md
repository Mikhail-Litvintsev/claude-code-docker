# Claude Code Docker

A wrapper that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside per-project Docker containers. One OAuth login per host or one per project account, a separate container per session, transparent integration with project compose networks and service containers (VPN, proxies, etc.).

Tested on **Ubuntu 22.04+**. A host-side `claude` binary is not required — `ccd` runs an isolated CC instance from the `claude-cc-bin` docker volume.

---

## Why

- **`--dangerously-skip-permissions` without the risk.** CC runs without `Bash`/`Edit`/`Write` confirmations; protection is enforced at the container layer rather than via prompts: docker API through a whitelisted proxy, `--cap-drop=ALL` + `no-new-privileges`, sanitized git identity, no access to the host's `~/.ssh/`, `~/.aws/`, or `~/.bashrc`.
- **One container, one project.** Bind-mounts only the current project directory.
- **Compose-network attach.** Inside a session, `db`, `redis`, etc. are visible by their compose names.
- **Shared or per-project OAuth login.** One-time OAuth, stored in the `claude-auth` volume and reused across projects; a project with its own Claude subscription gets its own volume and config dir (`CLAUDE_ACCOUNT`), and a guard hook refuses prompts under any other account.
- **Idempotent bootstrap.** `init.sh` can be re-run safely — a repeat run rebuilds nothing.

---

## Architecture

```
<setup>/                                    setup repository
├── Dockerfile, init.sh, connect-project.md, project-account.md
├── bin/ccd                                 launcher wrapper
├── bin/claude-host                         host-side claude launcher honoring the project account
├── cc-docker-proxy/haproxy.cfg             docker API whitelist
├── lib/init-helpers.sh, project-template/  helpers + project template
├── lib/api-broker.py                       API broker for the gateway container (keys stay in the gateway)
├── lib/claude-account.sh, claude-account-guard.sh  project account resolution + UserPromptSubmit guard hook
└── <project-name>/                         per-project settings (NOT in repo)
    ├── init.sh                             project initializer
    ├── ccd-config.sh                       generated (outside the project bind-mount — anti-tampering)
    ├── ccd-pre-start.sh (opt.)             hook sourced by ccd before session launch
    ├── mcp.json                            project-level MCP
    ├── Dockerfile (opt.) FROM cc-image
    ├── ssh-known-hosts (opt.)              host keys of corporate git hosts, appended into the image by Dockerfile
    ├── Dockerfile.vpn + vpn-config/ (opt.) xray gateway; vpn-entrypoint.sh when it also runs the API broker
    └── Dockerfile.<svc> + <svc>-config/ (opt.) service containers

<projects-root>/<project-name>/             project source (separate repo, or a workspace over repos)
└── .claude/{<name>-credentials.env, <mcp-server>-config.json, cc-<project-name>-vpn.users, scripts/}

~/.config/ticket-services/<project-name>.env  API keys of the ticket tracker and code host; mounted read-only into the gateway only
~/.config/xray-<project-name>/ (opt.)       vpn-config shared with the host xray service instead of <setup>/<project-name>/vpn-config/
```

| Resource | Purpose |
|---|---|
| `cc-image` | base image (FROM `node:22-slim` + git/curl/jq/rg/docker-cli + document conversion: poppler-utils, LibreOffice headless, python3/openpyxl) |
| `cc-image-<project>` | (opt.) per-project extension |
| `cc-net` | docker network for service containers |
| `cc-docker-proxy` | docker.sock proxy with whitelist |
| `claude-auth` (volume) | shared OAuth token |
| `claude-auth-<account>` (volume) | OAuth token of one project account (`CLAUDE_ACCOUNT`), created by `ccd` on first use |
| `claude-cc-bin` (volume) | Claude Code binary, warmed up by `ccd` |
| `cc-<project>-<pid>` | ephemeral per-session container (`--rm`) |
| `cc-<project>-<svc>` | service container (refcount-managed by `ccd`) |
| `cc-<project>-vpn` | gateway: xray tunnel plus the API broker (`lib/api-broker.py`) that keeps the service keys in the gateway (`~/.config/ticket-services/` mounted read-only) and forwards only the routes of its allow-list; session containers reach it as `TICKET_SERVICES_BROKER` (`http://cc-<project>-vpn:8080`, passed through `CONTAINER_ENV`) |

---

## Requirements

- Linux (Ubuntu 22.04 / 24.04).
- Docker Engine 20.10+ with the Docker Compose v2 plugin.
- `jq`, `flock` (`util-linux`), `realpath` (`coreutils`).
- User in the `docker` group.

`init.sh` checks for these utilities itself and fails with a hint if any are missing.

---

## Installation

```bash
cd ~/projects   # or any other <projects-root>
git clone <repo-url> claude-code-docker
bash claude-code-docker/init.sh
source ~/.bashrc   # to pick up the new PATH
```

`init.sh` creates `cc-net`/`claude-auth`/`cc-docker-proxy`, builds `cc-image` against the host UID/GID, puts `<setup>/bin` first in PATH (it holds `ccd` and a `claude` that picks the project account), registers the account guard hook, and runs `<setup>/*/init.sh` for connected projects.

**Claude Code authorization (one-time):**

```bash
cd <projects-root>/<any-project>
ccd
```

The first run warms up `claude-cc-bin` (~30 sec) and CC initiates the OAuth flow inside the session. If auto-prompt does not fire, run `/login` inside the session. The token lives in `claude-auth` and is shared across all projects. A project with `CLAUDE_ACCOUNT` set repeats this step once in its own volume, see [Per-project Claude account](#per-project-claude-account).

---

## Usage

```bash
cd <projects-root>/<project-name>
ccd                       # interactive CC session
ccd -- <claude-flag>      # pass flags through to the claude CLI
```

`ccd` walks up from `$PWD` to the ancestor that is `<projects-root>/<name>` with a `<setup>/<name>/ccd-config.sh` (a same-named folder elsewhere is not a project), reads the config, starts service containers under refcount, then launches the CC container with the project bind-mount and compose networks attached. On exit — `--rm` plus refcount-driven service-container cleanup.

---

## Connecting a new project

`connect-project.md` is the spec for a Claude agent (run it in the native host-side `claude`). If no native CC is available, follow it manually using `lib/project-template/`.

**Short version:**

1. Create a paired `<setup>/<name>/` + `<projects-root>/<name>/` (same name).
2. Copy the needed files from `lib/project-template/` into `<setup>/<name>/`, replacing `expro` → `<name>`.
3. `bash <setup>/init.sh --project <name>`.
4. `cd <projects-root>/<name> && ccd` — project services should be visible inside the session.

`<setup>/<project-name>/` is excluded from the setup repo by the whitelist — it contains secrets.

A project on its own Claude subscription additionally follows `project-account.md`.

---

## Idempotency and rebuilds

`init.sh` is idempotent — `inspect → SKIP / create` for every resource.

| Flag | Effect |
|---|---|
| `--rebuild` | rebuild ALL images (shared + per-project + service) |
| `--skip-projects` | only the shared steps |
| `--project <name>` | only the named project's init.sh |

If the host UID/GID drifts from `cc-image`, the root `init.sh` rebuilds `cc-image` and forwards `--rebuild-base-derived` to project initializers — only `FROM cc-image` derivatives get rebuilt.

---

## Project `ccd-config.sh` configuration

A bash file with variables for the `ccd` wrapper. Lives in `<setup>/<project>/`, **not** in the project bind-mount — otherwise CC inside the session could rewrite `EXPOSE_GIT_PUSH=0` → `1`. Changes are picked up by the next session.

### Base variables

| Variable | Type | Purpose |
|---|---|---|
| `IMAGE` | string | CC container image: `cc-image-<project>` or `cc-image`. |
| `CONTAINER_NAME_PREFIX` | string | CC container name prefix (final name is `<prefix>-<pid>`). |
| `CLAUDE_ACCOUNT` | string | (opt.) Email of the claude.ai account whose subscription this project uses. Empty or unset: the shared login. See [Per-project Claude account](#per-project-claude-account). |
| `COMPOSE_NETWORKS` | bash array | List of compose networks. Empty `()` — no attach. |
| `VPN_CONTAINER` | string | VPN container name. `""` — no VPN. |
| `VPN_REFCOUNT_FILE` | path | Refcount file for active sessions holding the VPN open. |
| `VPN_IMAGE` | string | (opt.) VPN container image. Required for config-hash auto-recreation. |
| `VPN_CREATE_ARGS` | bash array | (opt.) Extra `docker create` args for the VPN container (`--network-alias <corporate-host>` per hostname it serves, volumes such as `vpn-config` and `~/.config/ticket-services` read-only). |
| `CONTAINER_ENV` | bash array | (opt.) `NAME=value` strings, each passed to the session container as `-e`. Used for `TICKET_SERVICES_BROKER`. Default `()`. |
| `SSH_AGENT_KEY` | path | (opt.) With `EXPOSE_GIT_PUSH=1`: `ccd` starts (or reuses) a dedicated ssh-agent at `${XDG_RUNTIME_DIR:-/tmp}/ccd-agent-<project>.sock`, loads only this key into it and mounts that socket as `/ssh-agent`; the user's own agent is never exposed. `ccd` exits with an error when the file is missing. Unset: the host `$SSH_AUTH_SOCK` is mounted. |

### Pre-start hook

If `<setup>/<project>/ccd-pre-start.sh` exists, `ccd` sources it before launching the session container. Use it for project-specific validation — e.g. checking that a service container's config (ports, env vars) matches `ccd-config.sh` and recreating it on drift.

When `VPN_IMAGE` and `VPN_CREATE_ARGS` are set in `ccd-config.sh`, the standard `ccd-pre-start.sh` computes a sha256 hash of `VPN_CREATE_ARGS`, stores it as a `ccd.config-hash` docker label on the VPN container, and compares on each run. Any mismatch (including a missing container) triggers automatic recreation — no manual `docker rm` needed.

### User-level hooks

Tools that are not part of ccd and not part of a project (a remote-control bridge, a telemetry sidecar, extra mounts) plug in through `${XDG_CONFIG_HOME:-$HOME/.config}/ccd/hooks.d/*.sh` (override the directory with `CCD_HOOKS_DIR`). `ccd` sources every `*.sh` there in lexical order right before `docker run`, after all its own `EXTRA_FLAGS` are assembled. A hook sees `PROJECT_NAME`, `PROJECT_DIR`, `CONTAINER_NAME`, `CONTAINER_HOME`, `IMAGE` and may append `docker run` options to the `EXTRA_FLAGS` array; a later `-e PATH=...` overrides the one ccd sets. Nothing in the setup dir or the project references these hooks, so removing the directory removes the integration.

### Git-RCE protection

| Variable | Default | What it does | What it breaks |
|---|---|---|---|
| `LOCK_GIT_INTERNALS` | `1` | Bind-mounts `.git/hooks` and `.git/config` for every `.git` directory in the project (`maxdepth 4`) as `:ro`. CC cannot write a malicious hook or per-repo `[alias] !cmd`/`[core] sshCommand`/`[filter "X"]`. | `git config --local`, `pre-commit install`/`husky install` from inside the session. |
| `LOCK_GITMODULES` | `0` | Bind-mounts `.gitmodules` as `:ro`. CC cannot swap submodule URLs. | `git submodule add` from inside the session. |

Audit (always on): a sha256 snapshot of `.git/hooks/*`, `.git/config`, `.gitattributes`, `.gitmodules` is taken at session start and compared on cleanup; any drift goes to stderr as a WARNING.

What flags do **not** close: local history mutations (`rebase`, `reset --hard`, `commit --amend`, `filter-branch`) — that is legitimate git use. Mitigation: `git fetch` + `git log -p` against a clean remote before pushing.

### Git access (opt-in)

| Variable | Default | What's exposed | Risk |
|---|---|---|---|
| `EXPOSE_GIT_IDENTITY` | `1` | sanitized `~/.gitconfig` + `[includeIf]` includes as `:ro` — `git commit` works with normal cascade | minimal |
| `EXPOSE_GIT_PUSH` | `0` | an ssh-agent socket as `/ssh-agent`: without `SSH_AGENT_KEY` the host `$SSH_AUTH_SOCK`, so `git push` via every key of the user's agent; with `SSH_AGENT_KEY` a dedicated agent holding that one key | medium without `SSH_AGENT_KEY`, low with it |
| `EXPOSE_GITCONFIG` | `0` | raw `~/.gitconfig` without sanitization — `signingkey`, `credential.helper`, `[url]` rewrites | high |

When `EXPOSE_GIT_IDENTITY=1`, the global gitconfig has the following stripped: `[credential]`, `[gpg]`, `[http]`, `[https]`, all `[url "..."]`, `*.signingkey`, `core.sshCommand`/`askpass`/`hooksPath`, `commit.gpgsign`/`tag.gpgsign`. Preserved: `user.name`, `user.email`, `pull.*`, `merge.*`, `rebase.*`, `alias.*`, `[includeIf]`.

| Scenario | `IDENTITY` | `PUSH` | `GITCONFIG` | When |
|---|---|---|---|---|
| Read-only analysis | `0` | `0` | `0` | Third-party code, untrusted PR. |
| **CC commits, user pushes** | `1` | `0` | `0` | **Default from the template.** |
| Full freedom | `1` | `1` | `0` | Trusted personal project, or `1` with `SSH_AGENT_KEY` set to the project's deploy key. |
| Custom gitconfig | — | — | `1` | GPG-signed commits, custom `[url]` rewrites. |

Unset `EXPOSE_*` = `0` (fail-secure). Unset `LOCK_GIT_INTERNALS` = `1` (fail-secure).

The XDG alternative (`~/.config/git/config`) is **not supported** — `bin/ccd` reads only `~/.gitconfig`. Either migrate, or configure per-repo via `git config --local`.

---

## Per-project Claude account

By default every session, host-side and ccd, uses the one login in `~/.claude` / the `claude-auth` volume. A project that runs on its own Claude subscription sets the email of that account in its `ccd-config.sh` (step-by-step procedure: `project-account.md`):

```bash
CLAUDE_ACCOUNT="dev@example.com"
```

The file lives outside the project bind-mount, so a session cannot change the binding. The account email becomes a slug (`dev-example-com`: lowercase, every run of other characters replaced by `-`) that names the account's storage.

**What it does**

| Where | Mechanism |
|---|---|
| `ccd` | mounts the volume `claude-auth-<slug>` instead of `claude-auth` at `/home/claude/.claude`. The volume is created on first use and holds only this account's login, so no other login can exist inside the project's sessions. The shared host files (`CLAUDE.md`, `settings*.json`, `agents/`, `skills/`, ...) are mounted on top as before. |
| `bin/claude-host` (`bin/claude` is a symlink to it) | host-side launcher. Finds the project from the current directory exactly like `ccd`; with `CLAUDE_ACCOUNT` it runs `claude` with `CLAUDE_CONFIG_DIR=~/.claude-<slug>`, otherwise it runs `claude` untouched. The directory is created on first use with symlinks to the shared files of `~/.claude` (the same list `ccd` mounts, plus `rules/`, `commands/`, `workflows/`, `plugins/`, `keybindings.json`, `themes/`); `.claude.json`, `.credentials.json` and `projects/` stay per account. The real binary is the first `claude` in `PATH` that is not the launcher itself; override with `CCD_HOST_CLAUDE=<path>`. |
| guard hook | `lib/claude-account-guard.sh`, registered by `init.sh` as a `UserPromptSubmit` hook in `~/.claude/settings.json` (host sessions read it directly, ccd mounts the settings file and the two `lib/claude-account*.sh` scripts). On every prompt it compares the account the project is bound to with `oauthAccount` of the session's config dir and exits with code 2 on a mismatch: the prompt is not sent, the message names both accounts. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` in the environment count as a mismatch, because they override the login. Inside a container the expected account comes from `CCD_CLAUDE_ACCOUNT`, set by `ccd`. |

**Host launchers.** `CLAUDE_CONFIG_DIR` is read only from the environment `claude` starts with (project settings cannot set it, by design of Claude Code), so the choice has to happen in the launcher. `init.sh` puts `<setup>/bin` first in PATH, and `bin/claude` there is a symlink to `claude-host`: a plain `claude` typed in any shell that loaded `~/.bashrc`, and anything such a shell starts, picks the project account by itself. Subagents and nested `claude` calls run inside the session and inherit it. Only tools that locate the binary on their own (remote-control bridges, IDE plugins with a configurable command, services started outside the shell) need their command setting pointed at `<setup>/bin/claude-host`; `init.sh` prints the reminder. Do not wrap `claude-host` in another script named `claude` on PATH: `claude-host` skips symlinks to itself when it looks for the real binary, but a wrapper script would loop and stop with an error. A session started past the launcher under the wrong login is stopped by the guard hook at its first prompt.

**First run per account.** `ccd` prints the volume it creates; the first session walks through onboarding and `/login`, sign in with the account from `CLAUDE_ACCOUNT`. `bin/claude-host` does the same for `~/.claude-<slug>`. The new config dir starts with an empty `.claude.json`: trust the project folder again and re-add user-scope MCP servers there once.

**Limits.** The guard blocks, it does not switch accounts: restart the session the right way. A directory `ccd` does not recognize as a project (a git worktree outside the project tree) gets no account and no check. `claude --bare` runs no settings hooks. Separate accounts do not add up usage limits; each session spends the subscription it is signed in with.

---

## MCP servers

Project-level MCP config is `<setup>/<project>/mcp.json` (outside the bind-mount — anti-tampering). `ccd` runs `claude --mcp-config <path> --strict-mcp-config`: every other source (`.mcp.json` in the project, `~/.claude.json` `projects[].mcpServers`) is ignored.

```json
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "/usr/local/bin/playwright-mcp",
      "args": [
        "--headless", "--isolated",
        "--config",     "<projects-root>/<project>/.claude/playwright-mcp-config.json",
        "--output-dir", "<projects-root>/<project>/.playwright-mcp"
      ]
    }
  }
}
```

> Use the baked binary `/usr/local/bin/playwright-mcp`, not `npx @playwright/mcp@latest`. The image installs `@playwright/mcp` plus a matching Chromium at build time. `npx ...@latest` re-resolves to a newer release whose Chromium revision was never installed, so every browser call fails with "browser is not installed". Rebuild the project image to update; the binary always matches its baked Chromium.

`<projects-root>/<project>/.claude/playwright-mcp-config.json` (generated by the project `init.sh`, referenced from `mcp.json` by absolute path):

```json
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "chromiumSandbox": false,
      "args": ["--host-resolver-rules=MAP *.<tld> <proxy-service-name>"]
    },
    "contextOptions": {
      "ignoreHTTPSErrors": true
    }
  }
}
```

> `chromiumSandbox: false` is mandatory under `--cap-drop=ALL`. The `args` line is only for dev domains served by a host-side nginx-proxy that the container cannot resolve; drop it when the app is reached by compose service name or `host.docker.internal:<port>`.

Chrome DevTools MCP (`chrome-devtools-mcp`: device emulation, network/CPU throttling, performance traces, Lighthouse, console and network inspection) is wired the same way. The project image installs `google-chrome-stable` from the Google apt repo plus `npm install -g chrome-devtools-mcp`; the server launches the system Chrome by channel, so no `--executablePath` is needed. Dockerfile example: `<setup>/lib/project-template/Dockerfile`.

```json
"chrome-devtools": {
  "type": "stdio",
  "command": "/usr/local/bin/chrome-devtools-mcp",
  "args": [
    "--headless", "--isolated",
    "--no-usage-statistics", "--no-performance-crux",
    "--chrome-arg=--no-sandbox",
    "--chrome-arg=--disable-setuid-sandbox",
    "--chrome-arg=--disable-dev-shm-usage",
    "--filesystem-root", "<projects-root>/<project>/.chrome-devtools-mcp"
  ],
  "env": {
    "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1",
    "CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY": "1"
  }
}
```

> `--filesystem-root` is where screenshots, traces and heap snapshots may be written; the directory must exist before the server starts (the project `init.sh` creates it), otherwise the root is dropped with `Could not resolve configured root`. `CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY=1` stops the server from picking up a `cd4a.config.json` planted in the project working directory, the same anti-tampering stance as `--strict-mcp-config`.

IDE-MCP (PhpStorm, etc.) is wired up separately — via an IDE lock-file bind-mount + `CLAUDE_CODE_SSE_PORT`.

---

## Security

CC runs with `--dangerously-skip-permissions`. Isolation:

1. **docker.sock proxy** (`tecnativa/docker-socket-proxy` + custom `haproxy.cfg`). Allowed: `containers/exec`/`start`/`stop`/`inspect`, `networks/inspect`. Denied: `containers/create` (explicit deny in `haproxy.cfg`), `build`, `images/pull`, `volumes/*`. An attacker cannot spawn a `--privileged` container.
2. **`--cap-drop=ALL`** + `--security-opt=no-new-privileges`.
3. **Opt-in git access** via `EXPOSE_GIT_*` (default `1/0/0`).
4. **`LOCK_GIT_INTERNALS=1`** (default) — `.git/hooks/*` and per-repo `.git/config` mounted `:ro`, git-RCE vectors closed.

**What an attacker via prompt injection CAN do:**
- Modify project files (revertible via git).
- Read the OAuth token from `claude-auth` and exfiltrate it (`claude /logout` + re-authorize).
- `docker compose exec` into a project compose container — runs with that container's privileges, **not** the host's.
- Reach neighboring compose stacks via attached networks.

**CANNOT:**
- Read the host's `~/.ssh/`, `~/.aws/`, or `~/.config/`. `~/.config/ticket-services/` is mounted read-only into the gateway container only: the session never sees the directory or the keys, it reaches the ticket tracker and the code host through the broker's allow-listed routes.
- Modify `~/.bashrc`/`authorized_keys`/cron.
- Escalate to root via docker.sock.
- Plant a malicious `.git/hooks/<name>` or `[alias] !cmd`/`[core] sshCommand` in per-repo `.git/config` (when `LOCK_GIT_INTERNALS=1`).

**When the model breaks:**
- `EXPOSE_GIT_PUSH=1` or `EXPOSE_GITCONFIG=1` — the agent gets ssh-agent (every key of the user's agent, or the one key of `SSH_AGENT_KEY`) / raw gitconfig.
- `LOCK_GIT_INTERNALS=0` — git-RCE vectors reopen (`.git/hooks/`, per-repo `[alias]`/`sshCommand`/`[filter]`).
- `-v /var/run/docker.sock:...` in a project Dockerfile, or publishing the proxy on a TCP port (`-p 2375:2375`).

For **full** isolation from project compose containers (untrusted code) — use a separate VM or rootless Docker.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `[FAIL] 'docker' not found` | install Docker Engine, add yourself to the `docker` group, log back in. |
| `[FAIL] 'docker compose' not working` | `apt install docker-compose-plugin`. |
| Files owned by `nobody:nogroup` after `ccd` | UID/GID mismatch — `bash init.sh` will rebuild `cc-image`. |
| OAuth flow does not start | run `/login` inside the session. |
| Prompt refused with `bound to the Claude account ...` | the session runs under another login than `CLAUDE_ACCOUNT` of the project: start it through `ccd` or `bin/claude-host`, or `/login` with that account. |
| `cc-<project>-vpn` does not start | `docker logs cc-<project>-vpn`, validate `<setup>/<project>/vpn-config/` with `xray run -test -c outbound.json -c routing.json -c inbounds-container.json`. |

---

## License

See `LICENSE` or contact the repository owner.
