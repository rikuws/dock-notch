# Shared by customize.sh and update.sh. A customized Dock Notch is a branch whose commits
# are your changes, on top of a release tag. Updating moves them onto a newer tag.

# The project this checkout follows when it has no `upstream` remote of its own. A fork
# that publishes releases for others to customize changes this to itself.
UPSTREAM_URL="${DN_UPSTREAM:-https://github.com/rikuws/dock-notch.git}"

die() {
    echo "$*" >&2
    exit 1
}

current_branch() {
    git symbolic-ref --quiet --short HEAD || die "HEAD is detached. Check out your branch first."
}

require_clean_tree() {
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
        || die "Commit your changes first: commits are what gets carried over to new releases."
}

rebase_in_progress() {
    [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]
}

# Sets UPSTREAM_REMOTE to the remote whose releases this checkout follows: `upstream` in
# a fork, otherwise `origin`. With `add`, a fork without an `upstream` remote gets one.
find_upstream() {
    if git remote get-url upstream >/dev/null 2>&1; then
        UPSTREAM_REMOTE=upstream
        return
    fi
    local origin
    origin="$(git remote get-url origin 2>/dev/null || true)"
    local project="${UPSTREAM_URL#https://github.com/}"
    project="${project%.git}"
    if [[ -n "$origin" && "$origin" == *"$project"* ]]; then
        UPSTREAM_REMOTE=origin
    elif [[ "${1:-}" == add ]]; then
        git remote add upstream "$UPSTREAM_URL"
        echo "Added the remote upstream ($UPSTREAM_URL) to follow its releases."
        UPSTREAM_REMOTE=upstream
    else
        UPSTREAM_REMOTE=origin
    fi
}

# The newest release tag on the upstream remote, like v0.3.0, fetched so it can be built on.
latest_release() {
    local tag
    tag="$(git ls-remote --tags --refs --sort=-v:refname "$UPSTREAM_REMOTE" 'v*' \
        | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    [[ -n "$tag" ]] || return 0
    git fetch --quiet --no-tags "$UPSTREAM_REMOTE" "+refs/tags/$tag:refs/tags/$tag"
    echo "$tag"
}

# The release the current branch is built on: the newest release tag in its history.
base_release() {
    git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true
}

# Opens your coding agent here with a prompt from prompts/, plus what's going on this
# time. The agent is DN_AGENT or `git config docknotch.agent` (a command the prompt is
# passed to as its last argument), otherwise Claude Code or Codex when installed.
# Returns non-zero when there's no agent to run.
run_agent() {
    local file="$1" context="${2:-}"
    local prompt
    prompt="$(cat "$file")"
    [[ -z "$context" ]] || prompt+=$'\n\n## This time\n\n'"$context"

    local agent="${DN_AGENT:-$(git config --get docknotch.agent || true)}"
    if [[ -z "$agent" ]]; then
        if command -v claude >/dev/null; then
            agent=claude
        elif command -v codex >/dev/null; then
            agent=codex
        fi
    fi
    if [[ -z "$agent" ]]; then
        echo
        echo "No coding agent found. Open yours in $PWD and give it $file."
        [[ -z "$context" ]] || echo "Tell it: $context"
        echo "To use one automatically next time: git config docknotch.agent \"<command>\""
        return 1
    fi

    echo
    echo "Starting $agent with $file. Quit it when it's done, and this carries on."
    local command
    read -ra command <<<"$agent"
    # Keeps `git rebase --continue` from waiting in an editor the agent can't use.
    GIT_EDITOR=true "${command[@]}" "$prompt" || true
}

# Builds the app and renders every card and popover with made-up data. Fails when the
# build fails or nothing renders.
build_and_check() {
    scripts/bundle.sh release || return 1
    local cards
    cards="$(mktemp -d)"
    build/DockNotch.app/Contents/MacOS/DockNotch --render "$cards" --sample --width 960 --details >/dev/null || return 1
    local rendered
    rendered="$(find "$cards" -name '*.png' | wc -l | tr -d ' ')"
    rm -rf "$cards"
    [[ "$rendered" -gt 0 ]] || return 1
    echo "Rendered $rendered cards and popovers."
}
