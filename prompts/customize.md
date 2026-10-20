# Customize Dock Notch

You're helping someone change their own copy of Dock Notch, a macOS app that fills the
space beside the Dock with their GitHub activity. This checkout is on a branch of their
changes, based on a release of the upstream project. Each new release, `make update` moves
their commits onto it, and you or another agent may be asked to carry over any that
clash. Work so that's easy.

## First

1. Read `README.md` for what the app does and how it's built, and `CUSTOMIZING.md` for how
   changes are kept across updates.
2. Read `mods/*.md` to see what's been changed already.
3. If "This time" below doesn't say what they'd like, ask them. Then say in a sentence or
   two what you'll change and where, and check it's what they meant before you start.

## How to make a change

- **One mod, one commit.** Each change they ask for is a mod: a commit whose message
  starts with `Mod:` (like `Mod: Show open issues`), holding the code and a file
  `mods/<short-name>.md`. Several requests make several commits.
- **Write the mod file for whoever updates it next.** It's what lets the change be redone
  when the code under it has moved. Say what the change is for and what it looks like from
  the user's side, which upstream files it hooks into and how, and how to tell it still
  works. Write the outcome, not a diff:

  ```markdown
  # Show open issues

  A tile beside the others counts open issues assigned to me, and its popover lists them.

  - Fetched in the same GraphQL query (GitHubClient.swift), as `issues: search(...)`.
  - New tile kind `.issues` in StripLayout.swift, added last so the others keep their order.
  - Check: `swift run DockNotch --render /tmp/cards --sample --width 1100 --details` shows
    the tile and its popover.
  ```

- **Keep new code in new files** under `Sources/DockNotch/Mods/`. Upstream never puts
  anything there, so those files never clash. Keep edits to upstream files to the few
  lines that hook your code in, and don't reformat, rename or move upstream code.
- **Changing an earlier mod?** Fold the fix into its commit, so each mod stays one commit:
  `git commit --fixup=<its sha>`, then
  `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $(git describe --tags --abbrev=0 --match 'v[0-9]*')`.
  Update its `mods/` file too.
- **Removing a mod?** Revert its commit, or drop it with an autosquash-style rebase.
- **Settings over code** where it fits: for something they'd want to tune, read a
  `defaults` key the way `Settings.swift` does and document it in the mod file.
- Never commit secrets, tokens or anything personal beyond what they ask for.

## Check it

1. `swift build` has no errors or new warnings.
2. Render the cards with made-up data and look at the PNGs:
   `swift run DockNotch --render /tmp/cards --sample --width 960 --details`
   (and `--width 625` for a narrower Dock). Use live data by leaving out `--sample`.
3. `make install` builds the app, installs it in /Applications and relaunches it. macOS may
   ask for Accessibility again if the signature changed (see CUSTOMIZING.md).

When it works, commit, then tell them in a few lines what changed, how to see it, and that
`make update` (or Check for Updates in the strip's right-click menu) keeps it on new
releases.
