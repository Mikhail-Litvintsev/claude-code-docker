# Setting up a fresh Ubuntu host

Everything `ccd` relies on that is not in this repository: what `init.sh` recreates by itself, what `ccd` creates on first use, what has to be carried over from the old machine by hand, and what belongs to other tools but hooks into `ccd`. Use it as the checklist when the setup moves to a new machine, and as the place to look when something works on one machine and not on another.

Ubuntu only (22.04 or newer). Placeholders: `<projects-root>` is the folder that holds every project, `<setup>` is `<projects-root>/claude-code-docker`.

## 1. What lives outside the repository

| Item | Where | Created by | On a new machine |
|---|---|---|---|
| `cc-net`, `claude-auth`, `cc-docker-proxy`, `cc-image` | docker | `init.sh` | recreated by `init.sh` |
| `cc-image-<project>`, gateway and service images and containers | docker | `<setup>/<project>/init.sh` | recreated by `init.sh` |
| `claude-cc-bin`, `claude-auth-<slug>`, `~/.cache/ccd/`, refcount files, the dedicated ssh-agent socket | docker, `$HOME`, `$XDG_RUNTIME_DIR` | `ccd` | recreated on first use |
| PATH line in `~/.bashrc`, guard hook in `~/.claude/settings.json` | `$HOME` | `init.sh` | re-added by `init.sh`; copies carrying the old path stay and must go, section 3 |
| `<setup>/<project>/` folders: `ccd-config.sh`, `mcp.json`, `Dockerfile*`, `vpn-config/outbound.json`, `ssh-known-hosts` | setup folder, excluded from git | project connection | copy from the old machine, section 5 |
| `<projects-root>/<project>/.claude/`: credentials env files, MCP configs, local settings | project folder, usually git-ignored | project `init.sh` and the user | copy from the old machine, section 5 |
| `~/.config/ticket-services/<project>.env`, `~/.config/xray-<project>/` | `$HOME` | the user | copy from the old machine, section 5 |
| `~/.gitconfig`, `~/.ssh/` (keys named in `SSH_AGENT_KEY`, `~/.ssh/config`) | `$HOME` | the user | copy or recreate, section 5 |
| Host `~/.claude/` (`CLAUDE.md`, `settings.json`, `agents/`, `skills/`, `scripts/`, `guidelines/`) | `$HOME` | the user's dotfiles repository | restore before `init.sh` and the first `claude` run, section 5 |
| Logins: `~/.claude.json`, `~/.claude/.credentials.json`, the `claude-auth*` volumes, `~/.claude-<slug>/` | `$HOME`, docker | `/login` (`claude-host` creates the directory) | log in again, section 6 |
| User-scope MCP servers, workspace trust, plugins | `~/.claude.json`, `~/.claude/plugins/` | the user | re-add, section 6 |
| `~/.config/ccd/hooks.d/*.sh`, bridge lines in `~/.bashrc`, user systemd units, IDE plugin setting, ufw rules | `$HOME`, `/etc` | other tools | per tool, section 7 |

## 2. Inventory on the old machine

Run these before touching the new machine and keep the output.

```bash
grep -nE 'claude-code-docker|claude|happy|tmux|PATH=' ~/.bashrc
ls -l ~/.config/ccd/hooks.d/
ls ~/.config/systemd/user/*.service ~/.config/systemd/user/*.timer 2>/dev/null
grep -l "<projects-root>" ~/.config/systemd/user/* 2>/dev/null
ls -la ~/.config/ticket-services/ ~/.config/xray-*/ 2>/dev/null
grep -hE 'SSH_AGENT_KEY|\$HOME|/mnt|/home' <setup>/*/ccd-config.sh
jq '.hooks' ~/.claude/settings.json
jq '.mcpServers // {} | keys' ~/.claude.json
grep -h claudeCommand ~/.config/JetBrains/*/options/claude-code-plugin-settings.xml
docker volume ls --format '{{.Name}}' | grep -vE '^[0-9a-f]{64}$'
grep -nE '\.lc|\.test|\.local' /etc/hosts
xray version 2>/dev/null | head -1
ls <projects-root>/*.md
```

Each line answers one question: which lines of `~/.bashrc` are not written by `init.sh`; which user-level hooks exist and where their symlinks point; which user services exist and which of them reference the projects root; which secret directories exist; which host paths every project config needs; whether the guard hook carries an absolute path; which user-scope MCP servers to re-add; what the IDE plugin runs; which named volumes exist (per-account logins, bridge volumes); which dev domains the host resolves locally; which xray version the gateway images were built against; which notes are kept at the projects root outside any repository.

## 3. Choose the projects root first

Keep the same absolute path for `<projects-root>` on the new machine. Absolute paths to it are stored in places that travel between machines on their own:

- `~/.claude/settings.json`: the guard hook command `<setup>/lib/claude-account-guard.sh`. The file is in the user's dotfiles repository, so a restored copy carries the old path. A hook whose command does not exist prints an error on every prompt.
- `~/.bashrc`: the PATH marker line and the bridge launcher variable (`HAPPY_CLAUDE_PATH`).
- The IDE plugin command (`<setup>/bin/ccd`).
- Symlinks in `~/.config/ccd/hooks.d/` into the bridge's repository.
- `ExecStart` of user systemd units that run scripts from a project.
- `ccd-config.sh` values. The template uses `$HOME`, `$SETUP_DIR` and `$PROJECT_DIR`, but check with the grep from section 2.

If the path has to change, fix every item above by hand before running `init.sh`: its markers contain the old path, so it would add a second PATH line to `~/.bashrc` and a second hook entry to `settings.json` while the stale ones stay. Delete the old PATH line (the one ending in `# claude-code-docker:<old-setup>`) and drop the stale hook:

```bash
jq --arg old '<old-setup>/lib/claude-account-guard.sh' \
    'if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= (map(.hooks |= map(select(.command != $old))) | map(select(.hooks | length > 0))) else . end' \
    ~/.claude/settings.json > /tmp/settings.json && cat /tmp/settings.json > ~/.claude/settings.json
```

The projects root is also the anchor of project detection: `ccd` and `claude-host` recognize a project only at `<projects-root>/<name>` (and below it) when `<setup>/<name>/ccd-config.sh` exists. Projects kept elsewhere are not recognized.

## 4. System packages and base tools

Docker Engine from Docker's apt repository. Not the snap: it is confined and cannot bind-mount arbitrary host paths such as a projects root outside `$HOME`. Not Docker Desktop: its engine runs in a VM, bind mounts are limited to the directories shared with that VM, and file ownership does not map to the host UID the way `cc-image` expects. Install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, then:

```bash
sudo usermod -aG docker "$USER"      # log out and back in afterwards
sudo apt install -y jq util-linux coreutils git python3 openssh-client
loginctl enable-linger "$USER"       # user systemd units run without an open session
```

`python3` is used by hooks in the host `~/.claude/scripts/` and by `lib/xray-outbound-from-link.py`. `tmux` and Node.js are needed only by a remote-control bridge; note that MCP servers started with `npx` need `npm` in the PATH of the process that starts `claude`, and a daemon's PATH is not the shell's PATH.

Host-side Claude Code (native installer, lands in `~/.local/bin/claude`):

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

`ccd` does not need it: sessions run the binary from the `claude-cc-bin` volume. It is needed by `bin/claude-host`, by the `connect-project.md` flow and by a bridge.

`xray` in `/usr/local/bin` only when a project runs a host-side VPN service (section 7). Take the same version the gateway images use (`ARG XRAY_VERSION` in the project's `Dockerfile.vpn`).

## 5. Restore files that are not in any repository

In this order, because later steps mount or read them.

1. **Host `~/.claude/`** from the dotfiles repository, before `init.sh` and before the first `claude` run: both create files in `~/.claude/` (`init.sh` writes `settings.json` when it is missing), and `git clone` refuses a non-empty directory:

   ```bash
   git clone <dotfiles-url> ~/.claude
   ```

   `ccd` mounts only entries that exist (`CLAUDE.md`, `settings.json`, `settings.local.json`, `agents/`, `skills/`, `scripts/`, `output-styles/`, `guidelines/`), so a missing entry is silently absent in every session. `settings.local.json`, `.claude.json`, `.credentials.json`, `projects/` and `history.jsonl` are per machine and are not part of the repository.

2. **This repository**: `git clone <repo-url> <projects-root>/claude-code-docker`.

3. **Project folders of the setup**, excluded from git on purpose because they hold secrets. Copy each one from the old machine as it is, modes included:

   ```bash
   rsync -a --exclude __pycache__ old:<setup>/<project>/ <setup>/<project>/
   ```

   Repeat for every `<setup>/<project>/`. `vpn-config/outbound.json` is a secret: ssh or rsync only, never a chat or a repository.

4. **Project sources** at `<projects-root>/<project>/`: clone the repositories. Then copy the local, git-ignored part of `.claude/` (credentials env files, `playwright-mcp-config.json`, `settings.local.json`, adapted scripts). Refcount files and `.lock` files are regenerated and can be skipped. For an external project `<projects-root>/<project>/` is a workspace that is not a repository: copy its `.claude/` and re-clone the repositories inside it.

5. **Secret directories under `~/.config/`**: `ticket-services/` (directory 700, files 600) and `xray-<project>/` (directory 700, `outbound.json` 600). `rsync -a` preserves the modes.

6. **Git and ssh**: `~/.gitconfig` at this exact path (`ccd` does not read `~/.config/git/config`), including `http.<url>.proxy` entries for hosts reached through a VPN; the keys named in `SSH_AGENT_KEY` of each `ccd-config.sh` plus `~/.ssh/config` with its `ProxyCommand` blocks.

7. **Host-wide files**: dev domains in `/etc/hosts` that a host-side reverse proxy serves (the matching `--host-resolver-rules` lines in Playwright configs assume them); notes kept at `<projects-root>/*.md` (a port registry, host notes).

## 6. Run init.sh, then log in

```bash
bash <setup>/init.sh
source ~/.bashrc
```

`init.sh` needs internet access: it pulls the proxy image from Docker Hub, builds `cc-image` from Debian and Docker apt repositories, and the first `ccd` installs Claude Code from the npm registry. Start the compose stacks of the projects before `ccd`, otherwise the networks listed in `COMPOSE_NETWORKS` do not exist and the session cannot reach the services (a warning is printed, the session still starts).

Check the launcher order right after `source ~/.bashrc`:

```bash
type -P claude      # must print <setup>/bin/claude
```

`init.sh` appends its PATH line at the end of `~/.bashrc` on the first run and rewrites it in place later. Any line below it that prepends to PATH (nvm, `~/.local/bin`, an installer of another tool) puts the native binary ahead of the launcher again, and a plain `claude` in a project folder then ignores the project account. Keep the marker line after every other PATH line.

Log in, once per side and per account:

- `cd <projects-root>/<project-without-CLAUDE_ACCOUNT> && ccd`, then `/login`: the shared login in `claude-auth`.
- `cd <projects-root>/<project-without-CLAUDE_ACCOUNT> && claude`, then `/login`: the shared host login in `~/.claude`. Inside a project with `CLAUDE_ACCOUNT` both commands would log the account storage in instead.
- Every project with `CLAUDE_ACCOUNT` set: steps 2 and 3 of `project-account.md` (its own volume and its own `~/.claude-<slug>/`).

Per machine and per config dir, Claude Code also asks again for workspace trust of each project folder, and the user-scope MCP servers from the inventory have to be re-added (`claude mcp add --scope user ...`, inside the project folder for a per-account project). Plugins enabled in `settings.json` are expected to be installed from the marketplaces it lists on first start; `/plugin` shows whether they are, and installs them otherwise.

## 7. Tools around ccd that init.sh does not configure

**IDE plugin (JetBrains).** Settings, Tools, Claude Code: command `<setup>/bin/ccd`, "Accept connections from all network interfaces" on. The setting is stored per product and per version (`~/.config/JetBrains/<Product><version>/options/claude-code-plugin-settings.xml`), so every IDE and every major upgrade needs it again.

**Remote-control bridge (happy or similar).** Installed from its own repository, not from here. What it adds and what has to be restored:

- lines in `~/.bashrc` that `init.sh` does not know: the `claude` alias through the bridge, `export HAPPY_CLAUDE_PATH=<setup>/bin/claude-host` so that the alias and the daemon pick the project account, and a tmux autostart for ssh logins;
- its daemon as a user systemd unit, and the hook symlink in `~/.config/ccd/hooks.d/` that mounts the bridge into ccd sessions;
- its per-project docker volumes and the linking procedure, described in the bridge's documentation.

The daemon and the tmux server capture the environment when they start: after changing `~/.bashrc`, restart both, otherwise phone-initiated sessions keep the old launcher.

**Host-side VPN service of a project.** A user unit `~/.config/systemd/user/xray-<project>.service` reading `~/.config/xray-<project>/`, enabled with `systemctl --user enable --now`; the browser proxy extension profile, the IDE HTTP proxy and the `ProxyCommand` in `~/.ssh/config` that point at its local inbounds; a copy of `lib/xray-outbound-from-link.py` in `~/.local/bin` for link rotations. The project's own documentation holds the exact values.

**Firewall.** When `ufw` is active, host services that containers reach from `cc-net` (a bridge server, a reverse proxy) need an allow rule on the bridge interface of `cc-net`. Its name is `br-` plus the first twelve characters of the network id and differs on every machine:

```bash
echo "br-$(docker network inspect cc-net -f '{{.Id}}' | cut -c1-12)"
```

Re-create such rules with the new interface name; a rule copied from the old machine refers to an interface that does not exist.

## 8. Verification

```bash
type -P claude                                   # <setup>/bin/claude
command claude --version                         # the native binary answers through the launcher
jq '.hooks.UserPromptSubmit' ~/.claude/settings.json      # one entry with the current <setup> path
docker network inspect cc-net -f '{{.Name}}'; docker ps --filter name=cc-docker-proxy --format '{{.Status}}'
cd <projects-root>/<project> && ccd              # id inside: claude with the host UID/GID; /status shows the login
docker volume ls --filter name=claude-auth-      # one volume per CLAUDE_ACCOUNT in use
ls ~/.config/ccd/hooks.d/ ~/.config/systemd/user/    # bridge hook and units are back
systemctl --user is-active <unit>                # for every unit from the inventory
```

For a per-account project, run the checks of `project-account.md` section 4 as well.

## 9. Optional: carrying session history

Logins are redone, but history can be moved. Host sessions live in `~/.claude/projects/` (shared login) and `~/.claude-<slug>/projects/` (per account); copy the directories. ccd sessions live inside the `claude-auth*` volumes:

```bash
docker run --rm -v claude-auth:/v -v "$PWD":/b alpine tar czf /b/claude-auth.tgz -C /v projects
docker run --rm -v claude-auth:/v -v "$PWD":/b alpine tar xzf /b/claude-auth.tgz -C /v   # on the new machine, after init.sh
```

Only the `projects/` subtree is worth carrying; credentials and state files are per machine and are recreated by `/login`.
