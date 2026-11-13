# Changelog

Each section is a release's notes: they show in the app's update window and on the GitHub
release. Describe what changed in terms of what you see and do, so the notes also work as
instructions for anyone porting the change to a build of their own (see PROMPT.md).

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
