# Carry customizations over to a new Dock Notch release

You're helping someone keep their own changes to Dock Notch, a macOS app, while updating it
to a new upstream release. Their changes are commits on a branch, each one a mod with a
`Mod:` message and a description in `mods/<name>.md`. `make update` started moving those
commits onto the new release tag with `git rebase`, and stopped because one clashes with
the new code, or because the result doesn't build. "This time" below says which, and
names both releases and a backup branch of where they were.

The goal is every mod working on the new release as its `mods/` file describes, and
nothing upstream lost.

## Understand both sides first

1. `git status` shows where things stand. During a rebase, the commit being applied is in
   `git log -1 REBASE_HEAD`.
2. Read the new release's notes in `CHANGELOG.md` and see what upstream changed:
   `git diff <old release> <new release> --stat`, then the diff of the files involved.
3. Read the `mods/` file of each mod you touch. It says what the change is for and how to
   check it. That intent is what you're keeping, not the old lines.

## Resolve

- **A conflict:** for each conflicted file, keep upstream's new code and redo the mod's
  part on top of it, the way the mod would have been written against this release. If
  upstream moved or renamed what the mod hooked into, hook into the new place. If upstream
  now does what the mod did, drop the mod (say so, and delete its `mods/` file). Then
  `git add` the files and `git rebase --continue`. Repeat until the rebase is done.
- **A build failure after the rebase:** fix the mod's code, not upstream's, and fold the fix
  into that mod's commit:
  `git commit --fixup=<mod sha>` then
  `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <new release>`.
- Keep each mod one commit, keep new code in `Sources/DockNotch/Mods/`, and keep edits to
  upstream files to small hooks. Update a mod's `mods/` file if what it hooks into moved.
- If a mod can't be carried over without a decision only they can make, stop and ask. To
  start over: `git rebase --abort` (or `git reset --hard <backup branch>` once the rebase
  has finished).

## Check

1. `swift build` has no errors.
2. `swift run DockNotch --render /tmp/cards --sample --width 960 --details` renders, and
   each mod's own check from its `mods/` file passes.
3. `git log --oneline <new release>..HEAD` shows one commit per mod, and `git status` is
   clean.

Then tell them in a few lines what upstream changed, what you did with each mod, and
anything you dropped or weren't sure of. Ask them to quit this agent session so
`make update` can finish: it builds the app, installs it and relaunches it.
