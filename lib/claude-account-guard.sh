#!/bin/bash
# UserPromptSubmit hook: refuses a prompt when the session does not run under
# the Claude account the project is bound to (CLAUDE_ACCOUNT in ccd-config.sh).
# Inside a ccd container the expected account arrives as CCD_CLAUDE_ACCOUNT;
# on the host it is resolved from the hook's cwd via the setup dir.
set -uo pipefail

SETUP_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
# shellcheck source=/dev/null
source "$SETUP_DIR/lib/claude-account.sh"

hook_input=$(cat)
cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

expected=""
if [ -n "${CCD_CLAUDE_ACCOUNT+x}" ]; then
    expected=$(ccd_trim "$CCD_CLAUDE_ACCOUNT")
    project_label="${CCD_PROJECT_NAME:-$(basename "$cwd")}"
elif ccd_find_project "$SETUP_DIR" "$cwd"; then
    expected=$(ccd_project_account "$SETUP_DIR" "$PROJECT_NAME" "$PROJECT_DIR")
    project_label="$PROJECT_NAME"
fi
[ -n "$expected" ] || exit 0

for override in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
    if [ -n "${!override:-}" ]; then
        echo "ccd: project ${project_label} is bound to the Claude account ${expected}, but ${override} overrides the login in this session. Unset it and start the session through ccd or claude-host." >&2
        exit 2
    fi
done

actual=$(ccd_session_account)
if [ -n "$actual" ] && [ "${actual,,}" = "${expected,,}" ]; then
    exit 0
fi

echo "ccd: project ${project_label} is bound to the Claude account ${expected}; this session runs as ${actual:-an unknown account}. The prompt was not sent. Start the session through ccd or claude-host, or run /login with ${expected}." >&2
exit 2
