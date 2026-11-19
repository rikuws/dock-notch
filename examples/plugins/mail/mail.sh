#!/bin/sh
# Unread mail from the last day and a half in Mail.app's inboxes, flagged first, with
# Slack's notification emails in a section of their own. Mail only syncs while it's open,
# so this starts it hidden when it isn't running.
#
# Tune it with the settings at the top of mail.js.
pgrep -xq Mail || open -gja Mail
exec osascript -l JavaScript "$(dirname "$0")/mail.js"
