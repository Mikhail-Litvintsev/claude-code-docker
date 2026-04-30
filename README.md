# Claude Code Docker

A wrapper that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside per-project Docker containers. One OAuth token per host, a separate container per session, transparent integration with project compose networks and service containers (VPN, proxies, etc.).

Tested on **Ubuntu 22.04+**. A host-side `claude` binary is not required — `ccd` runs an isolated CC instance from the `claude-cc-bin` docker volume.

---

## Why

- **`--dangerously-skip-permissions` without the risk.** CC runs without `Bash`/`Edit`/`Write` confirmations; protection is enforced at the container layer rather than via prompts: docker API through a whitelisted proxy, `--cap-drop=ALL` + `no-new-privileges`, sanitized git identity, no access to the host's `~/.ssh/`, `~/.aws/`, or `~/.bashrc`.
- **One container, one project.** Bind-mounts only the current project directory.
- **Compose-network attach.** Inside a session, `db`, `redis`, etc. are visible by their compose names.
- **Shared OAuth token.** One-time OAuth, stored in the `claude-auth` volume, reused across projects.
- **Idempotent bootstrap.** `init.sh` can be re-run safely — a repeat run rebuilds nothing.

---

## Architecture

```
<setup>/                                    setup repository
├── Dockerfile, init.sh, connect-project.md
├── bin/ccd                                 launcher wrapper
├── cc-docker-proxy/haproxy.cfg             docker API whitelist
├── lib/init-helpers.sh, project-template/  helpers + project template
└── <project-name>/                         per-project settings (NOT in repo)
    ├── init.sh                             project initializer
    ├── ccd-config.sh                       generated (outside the project bind-mount — anti-tampering)
    ├── mcp.json                            project-level MCP
    ├── Dockerfile (opt.) FROM cc-image
    └── Dockerfile.<svc> + <svc>-config/ (opt.) service containers

<projects-root>/<project-name>/             project source (separate repo)
└── .claude/{<name>-credentials.env, scripts/}
```

| Resource | Purpose |
|---|---|
| `cc-image` | base image (FROM `node:22-slim` + git/curl/jq/rg/docker-cli) |
| `cc-image-<project>` | (opt.) per-project extension |
| `cc-net` | docker network for service containers |
| `cc-docker-proxy` | docker.sock proxy with whitelist |
| `claude-auth` (volume) | shared OAuth token |
| `claude-cc-bin` (volume) | Claude Code binary, warmed up by `ccd` |
| `cc-<project>-<pid>` | ephemeral per-session container (`--rm`) |
| `cc-<project>-<svc>` | service container (refcount-managed by `ccd`) |

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

`init.sh` creates `cc-net`/`claude-auth`/`cc-docker-proxy`, builds `cc-image` against the host UID/GID, appends `<setup>/bin` to PATH, and runs `<setup>/*/init.sh` for connected projects.

**Claude Code authorization (one-time):**

```bash
cd <projects-root>/<any-project>
ccd
```

The first run warms up `claude-cc-bin` (~30 sec) and CC initiates the OAuth flow inside the session. If auto-prompt does not fire, run `/login` inside the session. The token lives in `claude-auth` and is shared across all projects.

---

## Usage

```bash
cd <projects-root>/<project-name>
ccd                       # interactive CC session
ccd -- <claude-flag>      # pass flags through to the claude CLI
```

`ccd` walks up from `$PWD` to the ancestor that has `<setup>/<basename>/ccd-config.sh`, reads the config, starts service containers under refcount, then launches the CC container with the project bind-mount and compose networks attached. On exit — `--rm` plus refcount-driven service-container cleanup.

---

## Connecting a new project

`connect-project.md` is the spec for a Claude agent (run it in the native host-side `claude`). If no native CC is available, follow it manually using `lib/project-template/`.

**Short version:**

1. Create a paired `<setup>/<name>/` + `<projects-root>/<name>/` (same name).
2. Copy the needed files from `lib/project-template/` into `<setup>/<name>/`, replacing `expro` → `<name>`.
3. `bash <setup>/init.sh --project <name>`.
4. `cd <projects-root>/<name> && ccd` — project services should be visible inside the session.

`<setup>/<project-name>/` is excluded from the setup repo by the whitelist — it contains secrets.

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
| `COMPOSE_NETWORKS` | bash array | List of compose networks. Empty `()` — no attach. |
| `VPN_CONTAINER` | string | VPN container name. `""` — no VPN. |
| `VPN_REFCOUNT_FILE` | path | Refcount file for active sessions holding the VPN open. |

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
| `EXPOSE_GIT_PUSH` | `0` | `$SSH_AUTH_SOCK` — `git push` via every key in ssh-agent | medium |
| `EXPOSE_GITCONFIG` | `0` | raw `~/.gitconfig` without sanitization — `signingkey`, `credential.helper`, `[url]` rewrites | high |

When `EXPOSE_GIT_IDENTITY=1`, the global gitconfig has the following stripped: `[credential]`, `[gpg]`, `[http]`, `[https]`, all `[url "..."]`, `*.signingkey`, `core.sshCommand`/`askpass`/`hooksPath`, `commit.gpgsign`/`tag.gpgsign`. Preserved: `user.name`, `user.email`, `pull.*`, `merge.*`, `rebase.*`, `alias.*`, `[includeIf]`.

| Scenario | `IDENTITY` | `PUSH` | `GITCONFIG` | When |
|---|---|---|---|---|
| Read-only analysis | `0` | `0` | `0` | Third-party code, untrusted PR. |
| **CC commits, user pushes** | `1` | `0` | `0` | **Default from the template.** |
| Full freedom | `1` | `1` | `0` | Trusted personal project. |
| Custom gitconfig | — | — | `1` | GPG-signed commits, custom `[url]` rewrites. |

Unset `EXPOSE_*` = `0` (fail-secure). Unset `LOCK_GIT_INTERNALS` = `1` (fail-secure).

The XDG alternative (`~/.config/git/config`) is **not supported** — `bin/ccd` reads only `~/.gitconfig`. Either migrate, or configure per-repo via `git config --local`.

---

## MCP servers

Project-level MCP config is `<setup>/<project>/mcp.json` (outside the bind-mount — anti-tampering). `ccd` runs `claude --mcp-config <path> --strict-mcp-config`: every other source (`.mcp.json` in the project, `~/.claude.json` `projects[].mcpServers`) is ignored.

```json
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--browser=chromium"]
    }
  }
}
```

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
- Read the host's `~/.ssh/`, `~/.aws/`, or `~/.config/`.
- Modify `~/.bashrc`/`authorized_keys`/cron.
- Escalate to root via docker.sock.
- Plant a malicious `.git/hooks/<name>` or `[alias] !cmd`/`[core] sshCommand` in per-repo `.git/config` (when `LOCK_GIT_INTERNALS=1`).

**When the model breaks:**
- `EXPOSE_GIT_PUSH=1` or `EXPOSE_GITCONFIG=1` — the agent gets ssh-agent / raw gitconfig.
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
| `cc-<project>-vpn` does not start | `docker logs cc-<project>-vpn`, inspect `<setup>/<project>/vpn-config/`. |

---

## License

See `LICENSE` or contact the repository owner.
