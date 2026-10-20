#!/usr/bin/env bash
# Starts your own version of Dock Notch: puts this checkout on a branch of your changes
# based on the newest release, then opens your coding agent with prompts/customize.md.
#
#   make customize                              # the agent asks what you'd like
#   make customize IDEA="show my open issues"   # or tell it up front
#
# Your changes stay commits on top of the release. `make update`, or Check for Updates in
# the app, moves them onto each new release. See CUSTOMIZING.md.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib/custom.sh

IDEA="${1:-}"
BRANCH="${DN_BRANCH:-custom}"

require_clean_tree
find_upstream add

if [[ "$(current_branch)" != "$BRANCH" ]]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git switch "$BRANCH"
    else
        LATEST="$(latest_release)"
        [[ -n "$LATEST" ]] || die "$UPSTREAM_REMOTE has no releases to build on yet."
        git switch -c "$BRANCH" "$LATEST"
    fi
fi
echo "On $BRANCH, based on $(base_release) with $(git rev-list --count "$(base_release)..HEAD") change(s) of yours."

if [[ -n "$IDEA" ]]; then
    run_agent prompts/customize.md "The user would like: $IDEA" || true
else
    run_agent prompts/customize.md || true
fi
