#!/usr/bin/env bash
# Brings a build from source up to the newest release, keeping your changes:
#
#   1. Finds the newest release tag on the upstream repository.
#   2. Moves your commits from the release they're on onto that one (git rebase).
#   3. If a change clashes, or the result doesn't build, opens your coding agent with
#      prompts/update-custom.md to carry your changes over.
#   4. Builds, renders every card as a check, installs and relaunches.
#
# Where you were is kept as the branch backup/<branch>-<old release>.
#
#   make update [INSTALL_PATH=/Applications/DockNotch.app]
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib/custom.sh

INSTALL_PATH="${INSTALL_PATH:-/Applications/DockNotch.app}"

if rebase_in_progress; then
    die "An earlier update stopped partway. Finish the rebase (your agent can, with prompts/update-custom.md) and run make update again, or go back with: git rebase --abort"
fi
require_clean_tree
find_upstream

BRANCH="$(current_branch)"
BASE="$(base_release)"
LATEST="$(latest_release)"
[[ -n "$LATEST" ]] || die "$UPSTREAM_REMOTE has no releases yet."
[[ -n "$BASE" ]] || die "$BRANCH isn't based on a release. Start one with: make customize"
BACKUP="backup/$BRANCH-$BASE"

if [[ "$BASE" == "$LATEST" ]]; then
    echo "$BRANCH is on the newest release, $LATEST."
else
    CHANGES="$(git rev-list --count "$BASE..HEAD")"
    git branch -f "$BACKUP" HEAD
    echo "Moving $CHANGES change(s) from $BASE onto $LATEST. Where you were is kept as $BACKUP."
    if ! git rebase --onto "$LATEST" "$BASE"; then
        echo
        echo "Some of your changes clash with $LATEST."
        run_agent prompts/update-custom.md "Updating $BRANCH from $BASE to $LATEST. The rebase stopped at a conflict. Where the branch was before is saved as $BACKUP." \
            || die "When the rebase is done, run make update again. To go back: git rebase --abort"
        if rebase_in_progress; then
            die "The rebase isn't finished. When it is, run make update again. To go back: git rebase --abort"
        fi
    fi
fi

INSTALLED="$(plutil -extract DNSourceRevision raw "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$INSTALLED" == "$(git rev-parse --short HEAD)" ]]; then
    echo "$INSTALL_PATH is already this build."
    exit 0
fi

if ! build_and_check; then
    echo
    echo "Your changes don't build on $LATEST yet."
    run_agent prompts/update-custom.md "Updating $BRANCH from $BASE to $LATEST. Your changes are on $LATEST now, but scripts/bundle.sh or the --render check fails; run them to see why. Where the branch was before is saved as $BACKUP." \
        || die "When it builds, run make update again. To go back: git reset --hard $BACKUP"
    require_clean_tree
    build_and_check || die "It still doesn't build. To go back: git reset --hard $BACKUP"
fi

pkill -x DockNotch || true
if [[ "$(cd "$(dirname "$INSTALL_PATH")" 2>/dev/null && pwd -P)/$(basename "$INSTALL_PATH")" != "$PWD/build/DockNotch.app" ]]; then
    rm -rf "$INSTALL_PATH"
    ditto build/DockNotch.app "$INSTALL_PATH"
fi
open "$INSTALL_PATH"
echo "Dock Notch $(plutil -extract CFBundleShortVersionString raw "$INSTALL_PATH/Contents/Info.plist") with your changes is running from $INSTALL_PATH."
