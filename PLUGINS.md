# Plugins

A plugin adds sections to the morning window from anything a script can read: Mail, a
to-do app, an internal API, a file. It's a folder with a small manifest and a command that
prints JSON, and Dock Notch draws what it prints in its own style.

Plugins work with the downloaded app and stay put through its updates: they live outside
the app, and the JSON below is the whole contract between them. For changing the app itself,
see [CUSTOMIZING.md](CUSTOMIZING.md).

## Make one

Right-click the strip and choose **Open Plugins Folder**, which opens
`~/Library/Application Support/Dock Notch/Plugins/`. Each folder in it is a plugin:

```
Plugins/
  mail/
    plugin.json
    mail.sh
```

`plugin.json`:

```json
{
  "name": "Mail",
  "command": "./mail.sh",
  "order": 40,
  "timeout": 45
}
```

| Key | | What it does |
| --- | --- | --- |
| `name` | required | The section's title until the plugin runs, and what the permission row calls it |
| `command` | required | Run with `/bin/sh -c` in the plugin's folder, such as `./mail.sh` or `osascript -l JavaScript todo.js`. Its PATH includes Homebrew's |
| `order` | `50` | Where its sections go. Today's calendar is 10, review requests 20, your pull requests 30 |
| `timeout` | `30` | Seconds before the command is stopped |

The command gets `DOCKNOTCH_PLUGIN` (the folder's name) and `DOCKNOTCH_PLUGIN_DIR` in its
environment. It runs each time the morning window opens or refreshes (⌘R), and at launch.

**The first time**, the plugin shows a row asking you to allow it, with the command it
will run. Click it and the plugin runs from then on. If its `command` changes, it asks again.

## What it prints

One JSON object on stdout, and exit 0:

```json
{
  "sections": [
    {
      "title": "Mail",
      "trailing": "3 unread",
      "url": "message://",
      "note": "No unread mail",
      "rows": [
        {
          "symbol": "envelope.fill",
          "tint": "blue",
          "title": "Q4 planning notes",
          "lead": "Anna Virtanen",
          "leadTint": "blue",
          "detail": "8:12",
          "url": "message://%3Cid@example.com%3E"
        }
      ]
    }
  ]
}
```

**Section**

| Key | | What it does |
| --- | --- | --- |
| `title` | required | The heading |
| `trailing` | | A count or short note beside the heading |
| `url` | | Opened by clicking the heading |
| `note` | | Shown when there are no rows, like "Inbox zero" |
| `rows` | | The rows, in order. Keep it to about ten |
| `order` | the manifest's | Where this section goes, to place one plugin's sections apart |
| `id` | its position | Keeps keyboard selection steady across refreshes |

**Row**

| Key | | What it does |
| --- | --- | --- |
| `title` | required | The first line, up to two lines long |
| `lead` | | The start of the second line, in color: a sender, a time, a status |
| `leadTint` | `secondary` | `green`, `red`, `amber`, `blue`, `mint`, `primary`, `secondary` or `tertiary` |
| `detail` | | The rest of the second line, in gray |
| `symbol` | a dot | An [SF Symbol](https://developer.apple.com/sf-symbols/) name, like `envelope.fill` |
| `tint` | `secondary` | The symbol's color, from the same names |
| `avatar` | | An image URL, shown round instead of the symbol |
| `url` | | Opened by clicking the row or pressing ↩ on it. Any URL macOS can open: `https://`, `message://`, `things:///`, `slack://` |
| `id` | its position | Keeps keyboard selection steady across refreshes |

When something goes wrong, the window says so in the plugin's section: a `plugin.json` that
doesn't parse, a command that exits non-zero (with the last line of its stderr), output
that isn't valid (with where), or a command that takes too long.

## Reading other apps

A plugin can read other apps with AppleScript or JavaScript for Automation through
`osascript`. The first time, macOS asks whether Dock Notch may control that app; you can
change your mind under System Settings → Privacy & Security → Automation.

## Example: Mail

[examples/plugins/mail](examples/plugins/mail) shows unread mail from the last day and a
half in Mail.app, flagged first, with Slack's notification emails in a section of their
own. It works with any account Mail has, including Exchange accounts added under System
Settings → Internet Accounts. Copy the folder into your plugins folder:

```bash
cp -R examples/plugins/mail ~/Library/Application\ Support/Dock\ Notch/Plugins/
```

## Trying a plugin

Run its command in its folder and check the output is what you expect:

```bash
cd ~/Library/Application\ Support/Dock\ Notch/Plugins/mail
./mail.sh | python3 -m json.tool
```
