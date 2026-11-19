// Prints the Mail plugin's sections for Dock Notch. See PLUGINS.md for the format.
const HOURS = 36;          // How far back to look for unread mail.
const LIMIT = 8;           // Rows per section.
const SLACK = /@(.+\.)?slack(mail)?\.com>?$/i;  // Senders that count as Slack.

function run() {
  const Mail = Application("Mail");
  const since = new Date(Date.now() - HOURS * 3600 * 1000);
  const found = Mail.inbox.messages.whose({
    _and: [{ readStatus: false }, { dateReceived: { _greaterThan: since } }],
  });

  const count = found.length;
  const subjects = count ? found.subject() : [];
  const senders = count ? found.sender() : [];
  const dates = count ? found.dateReceived() : [];
  const flags = count ? found.flaggedStatus() : [];
  const ids = count ? found.messageId() : [];

  const messages = subjects.map((subject, i) => ({
    subject: subject || "(no subject)",
    sender: senders[i] || "",
    date: dates[i],
    flagged: flags[i],
    id: ids[i],
  }));
  messages.sort((a, b) => (b.flagged - a.flagged) || (b.date - a.date));

  const slack = messages.filter((m) => SLACK.test(m.sender));
  const mail = messages.filter((m) => !SLACK.test(m.sender));

  const sections = [{
    id: "mail",
    title: "Mail",
    trailing: mail.length ? `${mail.length} unread` : undefined,
    url: "message://",
    note: "No unread mail",
    rows: mail.slice(0, LIMIT).map((m) => row(m, m.flagged ? "flag.fill" : "envelope.fill", m.flagged ? "amber" : "blue")),
  }];
  if (slack.length) {
    sections.push({
      id: "slack",
      title: "Slack",
      trailing: `${slack.length}`,
      rows: slack.slice(0, LIMIT).map((m) => row(m, "bubble.left.and.bubble.right.fill", "amber")),
    });
  }
  return JSON.stringify({ sections });
}

function row(m, symbol, tint) {
  return {
    id: m.id,
    symbol,
    tint,
    title: m.subject,
    lead: name(m.sender),
    leadTint: tint,
    detail: when(m.date),
    url: "message://" + encodeURIComponent(`<${m.id}>`),
  };
}

// "Anna Virtanen <anna@example.com>" → "Anna Virtanen"
function name(sender) {
  const match = sender.match(/^\s*"?([^"<]+?)"?\s*<.*>\s*$/);
  return match ? match[1] : sender.replace(/[<>]/g, "");
}

function when(date) {
  const time = `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
  return date.toDateString() === new Date().toDateString() ? time : `yesterday ${time}`;
}
