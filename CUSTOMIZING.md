# Making Dock Notch your own

There are three ways to have a Dock Notch, and updates reach each of them:

| | What you run | How updates reach it |
| --- | --- | --- |
| **Download it** | The signed release | It updates itself. |
| **Change it with your coding agent** | The release's source with your changes on top | Your changes move onto each new release, and your agent carries over any that clash. |
| **Build it from PROMPT.md** | An app your agent wrote from a description | Your agent ports what each release changed in the description. |

## Change it with your coding agent

You need Xcode 16 or later, `gh` (see the README) and a coding agent. Claude Code and Codex
are found automatically; see [Choosing your agent](#choosing-your-agent) for others.

```bash
git clone https://github.com/rikuws/dock-notch.git
cd dock-notch
make customize IDEA="add a tile counting open issues assigned to me"
```

`make customize` puts the checkout on a branch called `custom`, starting from the newest
release, and opens your agent with [prompts/customize.md](prompts/customize.md). Leave out
`IDEA` and the agent asks what you'd like. It makes each change you ask for as a **mod**:
one commit starting `Mod:`, plus a short description in [mods/](mods/) of what the change
is for and how to check it. Then `make install` puts your version in /Applications in
place of the downloaded one, keeping your settings. Run `make customize` again whenever you
want another change.

If you forked the repository on GitHub, clone your fork instead. `make customize` adds the
original as the `upstream` remote, so you still follow its releases. Pushing your `custom`
branch backs it up, and GitHub Actions builds each push and attaches pictures of every
card.

## How updates reach your changes

Your version checks for new releases a few times a day. When one is out, it asks, and
**Update in Terminal** runs `make update` in your checkout. You can also choose **Check for
Updates** from the strip's right-click menu, or run `make update` yourself. It:

1. Finds the newest release and keeps where you are as a branch, like
   `backup/custom-v0.1.0`.
2. Moves your commits onto the new release with `git rebase`. Most of the time nothing
   clashes and this needs no help.
3. If a change clashes with the new code, opens your agent with
   [prompts/update-custom.md](prompts/update-custom.md). It reads what upstream changed and
   what each mod is for, redoes the mod on top of the new code, and finishes the rebase.
   Quit the agent when it's done and the update carries on.
4. Builds the app and renders every card and popover as a check. If that fails, your agent
   is asked to fix it.
5. Installs the new build where the old one was and relaunches it.

If it stops partway, it says why and how to go on. To go back to how things were:

```bash
git rebase --abort                        # while a rebase is still in progress
git reset --hard backup/custom-v0.1.0     # after it, then:
make install
```

### What keeps updates smooth

The agent prompt already asks for these, but they're worth knowing:

- **One mod, one commit**, with a file in `mods/` that says what it's for. That file is how
  the change gets redone when the code under it has moved.
- **New code in new files**, under `Sources/DockNotch/Mods/`. Upstream never puts anything
  there or in `mods/`, so those never clash.
- **Small hooks** into upstream files, with no reformatting or renaming around them.
- **A setting instead of a code change** where one exists (see the README).

## Choosing your agent

`make customize` and `make update` use `claude` or `codex`, whichever is installed, in an
interactive session you can watch and talk to. To use another, give the command that
takes a prompt as its last argument:

```bash
git config docknotch.agent "aider --message"
```

For a single run, set `DN_AGENT` instead. Without an agent, the scripts tell you which
prompt to give yours, and you run `make update` again when it's done.

## The Accessibility permission

macOS ties the Accessibility grant to the app's signature. `make install` signs with your
Apple Development certificate when you have one, so the grant survives rebuilds and
updates. You can make one for free: in Xcode, open Settings → Accounts, add your Apple ID,
then Manage Certificates → + → Apple Development. Without it, each build is signed ad hoc,
and macOS asks for Accessibility again after every update. If the strip stops following the
Dock, remove Dock Notch from System Settings → Privacy & Security → Accessibility and add it
again.

## Build it from PROMPT.md

[PROMPT.md](PROMPT.md) describes the whole app, closely enough for an agent to build it
without this source. Give it to your agent in an empty folder and write what you'd like
done differently under **Your changes**. Your agent writes its own code, so you can take it
anywhere.

Since your code isn't this project's, updates can't be merged in. Each release changes
PROMPT.md to describe what's new, and its release notes link to that difference. Give it to
your agent with [prompts/port-a-release.md](prompts/port-a-release.md), and it makes the
same change in your app.

## Sharing your version

A fork that publishes its own releases works like this project for the people who
customize it: set up releases as in [RELEASING.md](RELEASING.md), and point `UPSTREAM_URL`
in `scripts/lib/custom.sh`, `SUFeedURL` in `Support/Info.plist` and the bundle identifier
at your fork. Their changes then follow your releases, and yours follow this project's.

## Why it works this way

- **A modified app can't take a ready-made update.** A signed release is a whole new binary;
  installing it would replace your changes. So customized copies update from source, and
  only the official build uses Sparkle.
- **Most updates need no agent.** A rebase only clashes where a mod and upstream changed the
  same lines. When they do, the mod's description lets the agent redo the change rather
  than splice old lines into new code. Breaks a rebase can't see, like a function the mod
  calls being renamed, show up in the build and render check.
- **The agent is the part to watch.** Its session is interactive, the backup branch keeps
  where you were, and `git diff backup/custom-v0.1.0` shows everything that changed.
