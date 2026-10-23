# Binding a project to its own Claude subscription

Checklist for a project that must run on a separate claude.ai account (its own Pro/Max/Team subscription) instead of the shared login. The mechanism is described in README, section "Per-project Claude account"; this file is the procedure. Everything below is done once per project, except the first login, which is done once per account on each side (ccd and host).

Prerequisites, already in place after `bash <setup>/init.sh`:

- the guard hook `<setup>/lib/claude-account-guard.sh` is registered in `~/.claude/settings.json` (check: `jq '.hooks.UserPromptSubmit' ~/.claude/settings.json` lists it);
- `<setup>/bin` is first in PATH (check: `type -P claude` prints `<setup>/bin/claude`, a symlink to `claude-host`), so a plain `claude` picks the project account. Tools that locate the binary themselves (a remote-control bridge, an IDE plugin with its own command setting) must point at `<setup>/bin/claude-host`; one that bypasses it cannot send prompts under the wrong account, the guard hook stops them, but it cannot pick the right account either.

## 1. Bind the project

Add the account email to `<setup>/<project-name>/ccd-config.sh`:

```bash
CLAUDE_ACCOUNT="dev@example.com"
```

The email is compared case-insensitively with the login of the session. Its slug (`dev-example-com`: lowercase, every run of other characters replaced by `-`) names the storage: the docker volume `claude-auth-dev-example-com` and the host directory `~/.claude-dev-example-com`.

A project connected through `connect-project.md` gets the line from the template with an empty value; fill it in. For an older project whose `init.sh` carries its own template, add the line by hand, `ccd` treats a missing variable as empty.

## 2. First ccd session: log in

```bash
cd <projects-root>/<project-name>
ccd
```

`ccd` prints `creating auth volume claude-auth-<slug> ...` and starts the session in an empty config dir: Claude Code walks through onboarding and `/login`. Sign in with exactly the account from `CLAUDE_ACCOUNT`. Then check inside the session:

- `/status` shows that account in the `Email` row;
- a first prompt goes through. If it is refused with `bound to the Claude account ...`, the login belongs to another account: `/logout`, then `/login` again with the right one.

Nothing else is needed on the ccd side: the shared host files (`CLAUDE.md`, `settings*.json`, `agents/`, `skills/`, ...) are mounted into the account volume as before, and `<setup>/<project-name>/mcp.json` keeps providing the MCP servers.

## 3. First host session: log in, trust, MCP

```bash
cd <projects-root>/<project-name>
claude            # resolves to <setup>/bin/claude, a symlink to claude-host
```

`claude-host` (reached through the `claude` symlink) creates `~/.claude-<slug>` with symlinks to the shared files of `~/.claude` and starts Claude Code with `CLAUDE_CONFIG_DIR` pointing there. The directory starts with an empty `.claude.json`, so three things happen once:

1. Onboarding and `/login`: sign in with the account from `CLAUDE_ACCOUNT`; verify with `/status`.
2. Workspace trust: accept the trust dialog for the project folder.
3. User-scope MCP servers (`claude mcp list` with scope `user`) live in `.claude.json` and are therefore per account. Re-add them from inside the project folder, for example:

   ```bash
   cd <projects-root>/<project-name>
   claude-host mcp add --scope user <name> -- <command> [args]
   ```

   or copy the whole block from the shared config in one go (run while no session of that account is open):

   ```bash
   slug=<slug>
   jq -s '.[0] * {mcpServers: (.[1].mcpServers // {})}' \
       ~/.claude-$slug/.claude.json ~/.claude.json > ~/.claude-$slug/.claude.json.new \
       && mv ~/.claude-$slug/.claude.json.new ~/.claude-$slug/.claude.json
   ```

Sessions, prompt history and auto memory of the project now live under `~/.claude-<slug>/projects/`; earlier sessions of the folder stay under `~/.claude/projects/` and are not listed by `--resume` from the account dir.

## 4. Verify the binding

From the project folder:

```bash
CCD_HOST_CLAUDE=/usr/bin/env claude-host | grep CLAUDE_CONFIG_DIR   # prints ~/.claude-<slug>
docker volume ls --filter name=claude-auth-                           # lists claude-auth-<slug>
```

Negative test of the guard: start a session in the project folder with the shared login on purpose, `CLAUDE_CONFIG_DIR= ~/.local/bin/claude` (adjust the binary path), and send any prompt. Expected: the prompt is refused with `project <name> is bound to the Claude account <email>; this session runs as <shared email>`. Exit and start the session the normal way.

## 5. Moving an existing project to its own account

Same steps 1 to 4. Consequences to tell the user:

- ccd sessions of the project no longer see the history stored in the shared `claude-auth` volume (`--resume` lists only sessions made under the account);
- host sessions lose nothing on disk, but `--resume` and auto memory switch to `~/.claude-<slug>/projects/`;
- a session that was open at the time of the change keeps its old login until restarted; the guard hook starts refusing its prompts, which is the intended signal to restart.

## 6. Undoing the binding

Remove or empty `CLAUDE_ACCOUNT` in `ccd-config.sh`; the next session uses the shared login again. The account's storage is left in place and can be deleted when no project uses that account any more:

```bash
docker volume rm claude-auth-<slug>
rm -r ~/.claude-<slug>
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Prompt refused with `bound to the Claude account ..., this session runs as ...` | The session was started past `claude-host`/`ccd`, or `/login` was done with another account. Restart through the launcher; inside the right config dir, `/logout` and `/login` with the account from `CLAUDE_ACCOUNT`. |
| Prompt refused with `... runs as an unknown account` | Not logged in yet in this config dir, or the login state file is missing. Run `/login`. |
| Prompt refused with `ANTHROPIC_API_KEY overrides the login` (or `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`) | The environment forces another credential. Unset the variable in the shell or the launcher and restart. |
| `claude-host: no claude binary in PATH` | The real binary is not in `PATH` of the launcher's environment. Set `CCD_HOST_CLAUDE=/path/to/claude` where the launcher runs. |
| `claude-host: re-entered 9 times` | A script named `claude` on PATH execs `claude-host`, which then picks that script as the real binary. Replace the script with a symlink to `claude-host`, or set `CCD_HOST_CLAUDE`. |
| Skills, agents or `CLAUDE.md` missing in a host session of the account | `~/.claude-<slug>` was created before those entries existed in `~/.claude`; `claude-host` adds the missing symlinks on the next start. Entries created in `~/.claude` after the first run are picked up the same way. |
| `claude-host: ~/.claude-<slug>/<entry> is a real file, not a link` | Something replaced the symlink with a copy (a tool that writes files by rename). The copy no longer follows `~/.claude/<entry>`. Merge what differs into `~/.claude/<entry>`, delete the copy, start `claude-host` again to re-link. |
| A phone-initiated or other daemon-spawned session uses the shared login | The daemon started without the launcher setting (`HAPPY_CLAUDE_PATH` for happy). Restart the daemon from a shell where the variable is exported. |
