# Changelog

Each section is a release's notes: they show in the app's update window and on the GitHub
release. Describe what changed in terms of what you see and do, so the notes also work as
instructions for anyone porting the change to a build of their own (see PROMPT.md).

## 0.3.0

- **The morning window**: what to look at first thing, in one larger card. Today's
  meetings, the pull requests waiting for your review and your own open ones. It opens by
  itself the first time you're at the Mac each morning, and any time with **⌃⌥M** from any
  app, **Good Morning** in the right-click menu, or `docknotch://morning`.
- **Today** reads Calendar's accounts, Exchange and Google included, once you allow it from
  the row that offers it. A meeting with a Teams, Zoom, Meet or Webex link joins with a
  click, and the next one says how soon it starts.
- **Filters** for the morning window: named sets of GitHub search qualifiers, like
  `Work: -repo:acme/deps`, that hide repos there without touching the strip. Edit them in
  the window with **Edit Filters…** and switch with ← →.
- **Plugins** add your own sections to the morning window from anything a script can read,
  and keep working through updates. A plugin is a folder with a `plugin.json` and a
  command that prints JSON; **Open Plugins Folder** in the right-click menu shows where
  they go. Each asks once before it runs. PLUGINS.md has the format and an example that
  shows unread mail from Mail.app, with Slack's notification emails on their own.

## 0.2.0

- A larger window for looking at a section properly, whenever you want: every pull request
  waiting for your review, all your open PRs, the whole conversation. It's the popovers'
  style with a tab per section, opens with **Open Window** (⌘O) in the right-click menu,
  and is driven by the keyboard: ← → switch sections, ↑ ↓ pick a row, ↩ opens it, Esc
  closes.
- `docknotch://` links open it, so you can bind it to a hotkey in Raycast or Shortcuts:
  `docknotch://toggle/reviews` opens on your review requests and closes again, and
  `docknotch://show` opens on whatever new thing needs you. The README lists them all.
- The rotation takes its time where it matters. A card with something new that needs you,
  such as a review request or a failing check, stays up twice as long until you've seen it.
  Cards that are only numbers, like contributions and merges, pass more quickly and come
  round every other lap.
- With displays of different kinds, such as a Retina laptop and an external monitor, the
  strip no longer goes invisible after the Dock moves back and forth between them.

## 0.1.0

The first release.

- A strip of black boxes fills the space beside the Dock with your GitHub activity: a
  rotating card for contributions, open pull requests, the latest comment, review requests,
  CI checks and recent merges, plus tiles that keep key numbers in view when there's room.
- Rest the pointer on a box for a popover with the detail behind it, such as the whole
  conversation on a pull request or which checks failed.
- The strip matches the Dock's size and position and comes and goes with it.
- Signed and notarized, and keeps itself up to date. Right-click the strip for Check for
  Updates.
- Builds from source follow releases too, with your own changes carried over. See
  CUSTOMIZING.md.
