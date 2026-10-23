#!/bin/bash
# Shared by bin/ccd, bin/claude-host and lib/claude-account-guard.sh.
# Resolves the project for a directory and the Claude account bound to it.

CCD_SHARED_CLAUDE_ENTRIES=(
    CLAUDE.md
    settings.json
    settings.local.json
    agents
    skills
    scripts
    output-styles
    guidelines
)

CCD_HOST_ONLY_CLAUDE_ENTRIES=(
    rules
    commands
    workflows
    plugins
    keybindings.json
    themes
)

ccd_find_project() {
    local setup_dir="$1"
    local dir="$2"
    local projects_root candidate
    projects_root=$(dirname "$setup_dir")
    while [ "$dir" != "/" ]; do
        candidate=$(basename "$dir")
        if [ -f "$setup_dir/$candidate/ccd-config.sh" ] \
            && [ "$(realpath "$dir" 2>/dev/null)" = "$(realpath "$projects_root/$candidate" 2>/dev/null)" ]; then
            PROJECT_NAME="$candidate"
            PROJECT_DIR="$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

ccd_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

ccd_project_account() {
    local setup_dir="$1"
    local project_name="$2"
    local project_dir="$3"
    (
        set +eu
        SETUP_DIR="$setup_dir"
        PROJECT_NAME="$project_name"
        PROJECT_DIR="$project_dir"
        CLAUDE_ACCOUNT=""
        # shellcheck source=/dev/null
        source "$setup_dir/$project_name/ccd-config.sh" >/dev/null 2>&1
        ccd_trim "${CLAUDE_ACCOUNT:-}"
    )
}

ccd_account_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

ccd_account_volume() {
    printf 'claude-auth-%s' "$(ccd_account_slug "$1")"
}

ccd_account_home_dir() {
    printf '%s/.claude-%s' "$HOME" "$(ccd_account_slug "$1")"
}

ccd_ensure_account_home_dir() {
    local dir
    dir=$(ccd_account_home_dir "$1")
    mkdir -p "$dir"
    chmod 700 "$dir"
    local entry
    for entry in "${CCD_SHARED_CLAUDE_ENTRIES[@]}" "${CCD_HOST_ONLY_CLAUDE_ENTRIES[@]}"; do
        [ -e "$HOME/.claude/$entry" ] || continue
        if [ -L "$dir/$entry" ]; then
            continue
        elif [ -e "$dir/$entry" ]; then
            echo "claude-host: $dir/$entry is a real file, not a link to ~/.claude/$entry; the two can diverge" >&2
        else
            ln -s "$HOME/.claude/$entry" "$dir/$entry"
        fi
    done
    printf '%s' "$dir"
}

ccd_session_account() {
    local state_file
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        state_file="$CLAUDE_CONFIG_DIR/.claude.json"
    else
        state_file="$HOME/.claude.json"
    fi
    jq -r '.oauthAccount.emailAddress // empty' "$state_file" 2>/dev/null || true
}
