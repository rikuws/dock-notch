# Build Dock Notch

This is a prompt for a coding agent (Claude Code, Codex, Cursor or any other) to build
Dock Notch from scratch: a macOS app that fills the space beside the Dock with your GitHub
activity. Give the agent this whole file. Add what you'd like done differently at the end,
under **Your changes**, or tell the agent as it goes.

It describes **Dock Notch 0.1.0**. Each release updates this file, so the difference
between two versions of it is what changed (see "Later releases" at the end).

![The strip with two tiles](docs/strip.png)

---

## What you're building

A strip of black, rounded boxes sits beside the macOS Dock, the same height as the Dock's
glass and lined up with it, like an extension of the Dock. The first box is a **card** that
rotates through GitHub summaries: contributions, open pull requests, the latest comment,
review requests, CI checks and recent merges. When there's room, smaller **tiles** follow
it, each keeping one number in view. Resting the pointer on a box opens a **popover** above
it with the detail behind its number. Data comes from the GitHub CLI (`gh`), so there are no
tokens to set up.

## Ground rules

- **Swift 6 and SwiftUI, with AppKit** for windows, menus and events. macOS 14 or later.
- **A Swift package**, not an Xcode project: one executable target, built with
  `swift build`, plus a script that wraps the binary in an `.app` bundle and signs it.
- **No dependencies** beyond the system frameworks and `gh`.
- **An accessory app** (`LSUIElement`): no Dock icon, no menu bar. Everything happens on
  the strip and its right-click menu.
- Use your own bundle identifier (like `com.<you>.docknotch`) and say so in the README.
- Write a README covering requirements, running it, using it, settings and how it works.
- Record in the README which version of this file you built from, so later releases can be
  ported (see the end).

## Data

### Finding gh

Apps opened from Finder don't get the shell's PATH. Look for `gh` in this order and use
the first executable one: a path in the `ghPath` setting, `/opt/homebrew/bin/gh`,
`/usr/local/bin/gh`, `/run/current-system/sw/bin/gh`, `~/.nix-profile/bin/gh`,
`~/.local/bin/gh`, `/usr/bin/gh`, then whatever `/bin/zsh -lc 'command -v gh'` prints.
Run it with its own directory and the usual system ones at the front of PATH, and with
`GH_NO_UPDATE_NOTIFIER=1`, `GH_PROMPT_DISABLED=1` and `NO_COLOR=1`. Drain stdout and stderr
concurrently so neither pipe can fill up and stall it. Run it off the main thread.

### One query per refresh

Each refresh is a single `gh api graphql` call (2 points of the 5,000/hour limit), passing
four search strings as variables. `<scope>` is the `searchQualifier` setting with a leading
space, or nothing; `<week ago>` is today minus 7 days as `YYYY-MM-DD`:

- `authored`: `is:pr is:open author:@me archived:false<scope>`
- `review`: `is:pr is:open review-requested:@me archived:false sort:updated-desc<scope>`
- `merged`: `is:pr author:@me is:merged merged:>=<week ago> sort:updated-desc<scope>`
- `recent`: `is:pr is:open involves:@me archived:false sort:updated-desc<scope>` (only open
  PRs: talk on merged or closed ones is done with)

```graphql
query($authored: String!, $review: String!, $merged: String!, $recent: String!) {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks { contributionDays { contributionCount date } }
      }
    }
  }
  authored: search(query: $authored, type: ISSUE, first: 50) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url isDraft reviewDecision additions deletions updatedAt
        repository { nameWithOwner }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                state
                contexts(first: 50) {
                  nodes {
                    __typename
                    ... on CheckRun { name conclusion status }
                    ... on StatusContext { context state }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  reviewRequested: search(query: $review, type: ISSUE, first: 10) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url createdAt additions deletions
        repository { nameWithOwner }
        author { __typename login avatarUrl(size: 128) }
      }
    }
  }
  merged: search(query: $merged, type: ISSUE, first: 10) {
    issueCount
    nodes { ... on PullRequest { number title url mergedAt repository { nameWithOwner } } }
  }
  recent: search(query: $recent, type: ISSUE, first: 15) {
    nodes {
      ... on PullRequest {
        number title url
        repository { nameWithOwner }
        comments(last: 6) {
          nodes { id body createdAt url author { __typename login avatarUrl(size: 128) } }
        }
        reviews(last: 6) {
          nodes {
            id body state submittedAt url
            author { __typename login avatarUrl(size: 128) }
            comments(first: 3) { nodes { body path } }
          }
        }
      }
    }
  }
}
```

- `gh` exits non-zero when GraphQL reports errors even if partial data came back (an org
  that enforces SSO, say). Use the data whenever there is some.
- Decode search nodes leniently: a node that fails to decode (a non-PR, or null for one you
  can't see) is dropped, not the whole response.
- stderr mentioning `gh auth login` or "not logged in" means not signed in; no binary means
  gh isn't installed; anything else is a failure with that message.
- On a failed refresh, keep showing the last good data. Only show an error when there's
  nothing to show yet.

### What the boxes need

Shorten repositories to their name (`acme/app` → `app`); a PR's label is `app#42`.

- **Contributions**: the year's total; rolling 7-day sums of the daily counts, working back
  from today, up to 24 of them, oldest first (the last is "this week", the one before "last
  week"); the last 14 days as dates (midnight UTC) and counts; and the streak, counting days
  in a row with a contribution back from today, where an empty today doesn't break it yet.
- **Open PRs**: the total (`issueCount`) and, for the fetched ones, a review state (draft;
  approved when `reviewDecision` is `APPROVED`; changes requested for `CHANGES_REQUESTED`;
  otherwise waiting) and a checks state from the rollup (`SUCCESS` passing; `FAILURE` or
  `ERROR` failing; `PENDING` or `EXPECTED` pending; else none). Collect check names: a
  CheckRun not `COMPLETED` is running, one that concluded `FAILURE`, `TIMED_OUT`,
  `CANCELLED`, `STARTUP_FAILURE` or `ACTION_REQUIRED` failed; a StatusContext in `FAILURE` or
  `ERROR` failed and in `PENDING` or `EXPECTED` is running. Count approved, changes
  requested, awaiting review and drafts.
- **Checks**: across your open PRs, how many are passing, failing and pending, and the first
  failing one. None at all when no PR has checks.
- **Review requests**: the count, and each request's PR, author, avatar, when it was opened
  and its size, newest activity first.
- **Merged**: the count over the last 7 days, and each with when it merged.
- **Latest comment**: from comments and submitted reviews on the `recent` PRs, by people
  (skip authors whose `__typename` is `Bot` or whose login ends in `[bot]`). A review's text
  is its body, else its first inline comment, else "Approved these changes" or "Requested
  changes" for those verdicts; a plain review with no text is skipped. The latest is the
  newest by someone other than you; your own shows only when nobody else has said
  anything. Keep the last 6 comments and reviews on that PR, oldest first, as its
  conversation.
- For the card, flatten a comment to one line of plain text: drop HTML comments, fenced
  code and tags, strip heading, quote and list markers, resolve inline Markdown, collapse
  whitespace. For popovers, keep the Markdown but drop HTML comments, images and real HTML
  tags (only real ones, so `Array<Int>` in code survives), and turn `<br>` into newlines.

### Refresh and rotation

- Fetch every 60 seconds (`refreshInterval`, at least 20). The card rotates every 7 seconds
  (`rotationInterval`, at least 3) through the cards worth showing that no tile covers.
- **While the pointer is on the strip or a popover, nothing moves**: the card doesn't
  rotate or jump, and a fresh snapshot waits until the pointer leaves (Refresh Now still
  applies at once). After it leaves, the next rotation is at least half an interval away.
- After each refresh, compare with the last snapshot and draw attention to the first of
  these that happened: a new latest comment from someone else; more review requests; more
  failing checks; more merges; a different number of open PRs; more contributions. If a
  tile shows it, that tile glows; otherwise the card jumps to it and glows, and stays 1.6
  times as long.
- Load avatars once and keep them, so rotating back never flashes a placeholder.

## The strip

### Cards

Each card has a caption, a headline, a footnote and an accessory on the right.

| Card | Caption | Headline | Footnote | Accessory |
| --- | --- | --- | --- | --- |
| Contributions | Contributions in the last year | the total | ↑/↓ "N this week" (green when up), " (M the week before)"; "Quiet couple of weeks" when both are 0 | the weekly chart |
| Open PRs | Your open pull requests | "N open" | "N approved" in green if any, else the first of awaiting review / need changes / drafts, then the rest joined by " · " | `arrow.triangle.pull` |
| Latest comment | Latest comment on app#42 | the comment in quotes | "@author" (or "You") · how long ago · PR title | the author's avatar |
| Review requests | Waiting for your review | "N pull request(s)" | "@author" · title of the newest | that author's avatar |
| Checks | Checks on your open pull requests | "N/M passing" | "N failing" · first failing PR in red; else "N running" in amber; else "All checks passing" in green | `xmark.seal` or `checkmark.seal` |
| Merged | Merged in the last 7 days | "N merged" | label and title of the latest | `arrow.triangle.merge` |

- The number in a headline is large; the words after it are dimmed.
- Comments, review requests, checks and merges only rotate in when they have something.
- Before the first data: "GitHub" / "Fetching…" / "Asking gh about your pull requests".
  Without gh: "Install gh" with "brew install gh, then gh auth login". Not signed in: "Not
  signed in" with "gh auth login in a terminal". Other errors: "Retrying soon" with the
  message.
- Times read "just now", "5m ago", "3h ago", "2d ago", then a date like "Oct 3".

### Tiles

Tiles are added in this order as space allows, each taking its card out of the rotation
(This week doesn't: the contributions card also has the yearly total and chart).

| Tile | Number | Status line |
| --- | --- | --- |
| Open PRs | total | "N approved" green, else "N to fix" amber, else "N in review", else "N drafts", else "none" |
| To review | count | "@newest author" green, or "all clear" |
| Checks | passing/total | "N failing" red, else "N running" amber, else "passing" green; "–" and "no runs" without checks |
| Merged | count | "last 7 days", green when any |
| This week | this week's contributions | "+N vs last" green, or "-N vs last" |

### Layout

All sizes are for an 84pt-tall strip, the default Dock, and scale with the strip's
height: `scale = height / 84`.

- The gap between boxes, and between the strip and the Dock or screen edge, is 10pt.
- The card prefers 400pt. Tiles are all one width, 104pt, like Dock icons. As many tiles
  fit as `(available width − 400) / (104 + gap)`, up to `maxTiles` (default 5). The card
  then takes whatever's left, up to 600pt.
- Corner radius 24. Content starts 20pt in. Avatars and symbols sit in a 64pt square inset
  10pt, like a Dock icon, with corners concentric to the box's (radius 14).
- Text, top to bottom: 13pt caption in secondary; a 33pt-tall headline row with 29pt
  semibold monospaced-digit text (18pt semibold for a quote) kerned −0.4; a 13pt footnote
  whose lead is medium weight and tinted, after an optional 12pt semibold symbol. Nudge the
  stack up half a point. Text keeps clear of the accessory (64pt plus insets), but may run
  into the chart's faded edge (keep clear of 36% of the width).
- Tiles: 13pt horizontal padding, caption, number, status line, one line each.

### Look

- Colors: green `rgb(0.25, 0.73, 0.31)`, mint `rgb(0.40, 0.92, 0.55)`, red
  `rgb(0.97, 0.32, 0.29)`, amber `rgb(0.89, 0.66, 0.20)`, links `rgb(0.45, 0.68, 1.0)`.
  White text at 96% (primary), 55% (secondary) and 36% (tertiary).
- Each box is black with a 1pt hairline of white at 9%, a tight shadow (black 35%, radius 1,
  y 1) under a soft one (black 28%, radius 12, y 5). Leave 20pt of transparent window
  around the boxes so shadows and glows aren't clipped.
- The glow: a 1.5pt green border at 85% and a green shadow at 50% with radius 12, rising
  over 0.25s, holding 0.5s and fading over 1.8s.
- Accessory squares: a vertical gradient from white 17% to white 7%, a 1pt border of white
  at 12%, 26pt semibold symbols.
- The chart is an area 46% of the card's width, flush with its right and bottom edges: one
  point per week, from 92% of the height down by up to 78% at the peak, filled with green
  going from 95% to 35% to 10% opacity downwards, topped with a 1.6pt round mint line. It
  fades in from transparent at its left edge to solid at 45%, and draws in from the left
  over 1.1s (ease out, after 0.15s) when it appears.

### Motion

- When the card changes, each row (caption, headline, footnote, accessory) of the old card
  lifts out (up 12pt, blur 5, fade; quick spring) while the new one rises in (from 14pt
  below, blur 5; spring 0.55s with a little bounce), staggered 0.045s per row.
- Numbers tick with numeric text transitions. Tiles enter and leave scaling from 85% at
  their leading edge with a fade, and the strip reflows with a gentle spring.
- With Reduce Motion, use plain crossfades and no chart reveal.

## Following the Dock

### Measuring it

- With Accessibility access, read the Dock's frame from its accessibility tree: the
  `com.apple.dock` process's child element with role `AXList`, its position and size.
  Accessibility uses a top-left origin on the primary screen; convert to Cocoa's
  bottom-left. Set a 0.25s messaging timeout. While the Dock is busy removing a quitting
  app's icon it may not answer: keep the last frame then.
- The edge is the bottom when the frame is wider than tall, else left or right of the
  screen's middle.
- A hidden Dock (auto-hidden, or behind a full-screen app) slides off screen. Once its frame
  is more than halfway past the edge, count it as hidden, and remember where it will
  appear (6pt above the bottom edge, or 4pt in from a side).
- On macOS 26 the accessibility frame sits about 4.5pt above the glass you see. When the
  screen reserves room for the Dock, align the frame's bottom so its top meets the top of
  that reserved area (`visibleFrame.minY`).
- Without Accessibility access, estimate from the room each screen reserves: at the bottom,
  a strip of `reserved − 6` from 6pt above the edge (on macOS 26 a 90pt reserved strip
  holds an 84pt Dock whose glass ends at its top); on a side, the reserved width. The
  Dock's length is unknown then. When no screen reserves room, a full-screen app covers the
  Dock, unless the Dock auto-hides (read `autohide` from `com.apple.dock`'s preferences), in
  which case it can't be followed: sit at the bottom of the main screen and stay up.
- Ask for Accessibility once, on first launch, and offer it again from the menu while it
  isn't granted.

### Polling

Measure once a second; every 60ms for 1.5s after an app launches or quits, the active
Space changes or screens change, so the strip follows the Dock's resize animation; and
every 250ms while the Dock is hidden, since nothing announces it coming back. While the
pointer moves within the Dock's thickness plus 40pt of an edge that doesn't reserve room
(where an auto-hiding Dock appears), poll quickly too.

### Placing the strip

- Height: the Dock's thickness, kept between 60 and 128pt.
- Bottom Dock, measured: the strip starts one gap after the Dock's right end and may fill
  to one gap before the screen's right edge, centered on the Dock vertically. Unmeasured:
  one card's width at the right edge. Left or right Dock: a row one gap below the Dock's
  lower end, starting where the strip's height centered in the Dock's thickness would, and
  running across the screen toward the other side.
- At least 300pt wide (scaled). Lay out in the available width, then shrink the window to
  what the layout uses, keeping it against the Dock. Keep it on the Dock's screen, 8pt from
  the sides and 4pt from the bottom.
- The strip is only out while the Dock is. When the Dock hides, the strip slides past the
  screen edge the way the Dock went and fades (0.2s, ease in), then orders out. When the
  Dock comes back, it slides back in and fades up (0.3s, cubic 0.2, 0.9, 0.3, 1). Moves
  while shown animate the same way. **While the pointer is on the strip or a popover, it
  stays out** even if the Dock hides.

### The window

- A borderless, non-activating `NSPanel` one level above the Dock's window level, joining
  all Spaces, stationary, outside the window cycle, allowed over full-screen apps. Clear,
  no shadow, never key or main, not hidden on deactivate, no window animation.
- Accept first mouse, so a click works without activating the app first.
- **The app is rarely active, so AppKit doesn't send it mouse moves.** Track entering and
  leaving the strip with a tracking area that's always active, and while the pointer is
  inside, follow it with global and local event monitors to know which box it's over.
- Scrolling flips one card per gesture in either direction (vertical, or horizontal
  reversed). Ignore momentum. Trackpads need 14pt of travel; a wheel, any click.
- Clicking a box opens it on GitHub: your profile for contributions, `github.com/pulls` for
  open PRs, `github.com/pulls/review-requested` for reviews, the comment, the first failing
  PR (or your PRs) for checks, the latest merged PR. Without data, open cli.github.com.

### The right-click menu

Refresh Now (⌘R), Open GitHub, Enable Precise Dock Tracking… (only while Accessibility
isn't granted; it prompts and opens that pane of System Settings), Open at Login (a
checkmark, using `SMAppService.mainApp`), and Quit Dock Notch (⌘Q).

## Popovers

- Rest on a box for 350ms and its popover opens above it. While one is open, moving to
  another box switches at once. It closes 250ms after the pointer has left both the strip
  and the popover, which leaves room to cross the gap. Clicking a box closes its popover
  until the pointer moves to another box. Boxes with nothing more to say get none.
- A second panel like the strip's, one level higher. 380pt wide, at most 460pt tall, radius
  20, black, a 1pt border of white at 12%, the same two shadows a little stronger. It sits
  8pt above the box, centered on it, at least 8pt inside the screen. It goes below instead
  only when there's less than 240pt above and more room below. It opens by rising 6pt and
  fading in over 0.2s.
- Size it to its content by laying the same view out off screen. It scrolls only when the
  content doesn't fit; a conversation opens scrolled to the bottom.
- A header: an optional 11.5pt caption, a 14pt semibold title of up to two lines, and an
  optional 12pt figure on the right. A hairline under it. Clicking the header opens the
  page it's about.
- Rows: a 16pt symbol or 24pt avatar, a 13pt medium title of up to two lines, and an
  11.5pt line with a tinted, medium lead and the rest in secondary. The row under the
  pointer lights up (white at 8%, radius 10); clicking opens it on GitHub and closes the
  popover. At most 6 rows, then "N more on GitHub" when there are more.

| Box | Header | Content |
| --- | --- | --- |
| Open PRs | Your open pull requests, total | Most urgent first (failing checks, changes requested, approved, approved with checks running, in review, drafts), then most recently updated: "app#42 · +120 −8" with a lead like "lint failed" (red), "Changes requested" (amber), "Ready to merge" (green), "In review, checks running", "Draft" (tertiary) |
| To review | Waiting for your review, count | Avatar, "@author · app#42 · +120 −8 · opened 2d ago" |
| Checks | Checks on your pull requests, "N/M passing" | Failing PRs with the names of what failed ("build, lint and 3 more failed"), then running ones; when nothing needs attention, the passing ones, otherwise "N more passing" with up to three labels |
| Merged | Merged in the last 7 days, count | "app#42 · merged 3h ago" |
| Latest comment | The PR's label and title | The conversation (below) |
| Contributions, This week | Your last two weeks, "N this week" | The activity view (below) |

- **Conversation**: each comment or review with a 26pt avatar, the author in 12.5pt
  semibold, a verdict ("Approved" green, "Requested changes" amber, "Reviewed" for a review
  that's only inline comments), a green dot on the latest, and when. Then its Markdown in
  reading sizes: 13pt paragraphs with inline styling and links, headings in semibold,
  quotes with a 2pt bar, code in 11.5pt monospace on white at 7% (a `suggestion` block is
  labelled "Suggested change" in green; at most 12 lines), list items as bullets or ☐/☑,
  GitHub alerts (`> [!NOTE]`) as their word. Cut long comments at a word after about 1,400
  characters and add "Continues on GitHub". Inline review comments follow in boxes of white
  at 6% with their file path (truncated at the head) and up to 700 characters.
- **Activity**: 14 bars, one per day, up to 64pt tall by count (empty days a 3pt stub in
  white at 10%), this week in full green and the week before at 40%, each with its count
  above and its weekday letter below (today in primary and semibold). They grow from the
  bottom over 1.1s. Under them: the streak ("12-day streak", "…, nothing yet today", or "No
  streak going"), how this week compares ("up from", "down from", "same as the week
  before") and the busiest day.

## Settings

Read from `defaults` under your bundle identifier, applied on the next launch:
`searchQualifier` (none), `refreshInterval` (60), `rotationInterval` (7), `maxTiles` (5),
`ghPath` (auto).

## Checking your work

Add a development mode that renders without a screen:
`DockNotch --render <dir> [--sample] [--width <points>] [--details]` writes the strip as a
PNG (2x, on a colorful background) once per rotating card, at an 84pt height and the given
width of space beside the Dock; `--sample` uses made-up data that fills every card;
`--details` also writes each popover at its full height. Look at the images after each
change, at widths like 625 and 960. Then run the app, try a bottom, left and right Dock,
auto-hide, a full-screen app, and with and without Accessibility access.

## Packaging

A script that runs `swift build -c release`, makes `build/DockNotch.app` with the binary
and an Info.plist (`LSUIElement`, `NSHighResolutionCapable`, minimum system 14.0), and signs
it with an Apple Development identity when there is one (macOS ties the Accessibility grant
to the signature, and an ad-hoc one changes every build), else ad-hoc. A Makefile with
`run` (build and open) and `install` (copy to /Applications and open).

---

## Your changes

Anything you'd like different from the above. For example: other cards, other colors, a
different place on screen, data from somewhere other than GitHub.

-

---

## Later releases

When a newer Dock Notch is released, its PROMPT.md describes what changed. To bring your
build along, give your agent `prompts/port-a-release.md` from the new release with the
difference between the version you built from and the new one:
`https://github.com/rikuws/dock-notch/compare/v<yours>...v<new>` (the PROMPT.md part).
