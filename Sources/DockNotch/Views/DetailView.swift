import SwiftUI

/// Where the pointer is over the popover. The app is usually inactive, so SwiftUI's own
/// hover tracking stays quiet; the hosting view feeds this instead.
@MainActor
@Observable
final class DetailPointer {
    static let space = "detail"
    /// In the popover's top-left coordinate space, or nil when the pointer is elsewhere.
    var location: CGPoint?
}

enum DetailMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 460
    static let radius: CGFloat = 20
    /// Between the popover and the box it belongs to.
    static let gap: CGFloat = 8
}

/// The popover above a box: a header, then rows, a conversation or a chart. It takes the
/// height its content needs, and scrolls only when offered less than that.
struct DetailView: View {
    let model: DetailModel?
    let avatars: AvatarCache
    let pointer: DetailPointer
    let open: (URL) -> Void

    var body: some View {
        if let model {
            let shape = RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                header(model.header)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                ViewThatFits(in: .vertical) {
                    content(model.content)
                    ScrollView {
                        content(model.content)
                    }
                    .scrollIndicators(.never)
                    // A conversation reads up to the latest comment, at the bottom.
                    .defaultScrollAnchor(model.isConversation ? .bottom : .top)
                }
            }
            .frame(width: DetailMetrics.width, alignment: .leading)
            .background(shape.fill(.black))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
            .padding(notchShadowPadding)
            .coordinateSpace(.named(DetailPointer.space))
            .environment(\.openURL, OpenURLAction { url in
                open(url)
                return .handled
            })
            .environment(\.colorScheme, .dark)
            .tint(Palette.link)
        }
    }

    private func header(_ header: DetailModel.Header) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let caption = header.caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                }
                Text(header.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let trailing = header.trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .contentShape(Rectangle())
        .onTapGesture { header.url.map(open) }
    }

    @ViewBuilder
    private func content(_ content: DetailModel.Content) -> some View {
        switch content {
        case .rows(let rows, let more):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    RowView(row: row, avatars: avatars, pointer: pointer, open: open)
                }
                if let more {
                    RowView(row: more, avatars: avatars, pointer: pointer, open: open)
                }
            }
            .padding(6)
        case .conversation(let entries):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    EntryView(entry: entry, avatars: avatars, pointer: pointer, open: open)
                }
            }
            .padding(6)
        case .activity(let activity):
            ActivityView(activity: activity)
                .padding(16)
        }
    }
}

private extension DetailModel {
    var isConversation: Bool {
        if case .conversation = content { true } else { false }
    }
}

private struct RowView: View {
    let row: DetailModel.Row
    let avatars: AvatarCache
    let pointer: DetailPointer
    let open: (URL) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            switch row.leading {
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
            case .avatar(let url, let fallback):
                Avatar(url: url, fallback: fallback, size: 24, avatars: avatars)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(2)
                if !row.lead.isEmpty || !row.rest.isEmpty {
                    (Text(row.lead).foregroundStyle(row.leadTint).fontWeight(.medium)
                        + Text(row.rest).foregroundStyle(Palette.secondary))
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(Hoverable(pointer: pointer))
        .onTapGesture { row.url.map(open) }
    }
}

private struct EntryView: View {
    let entry: DetailModel.Entry
    let avatars: AvatarCache
    let pointer: DetailPointer
    let open: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: entry.avatar, fallback: "person.crop.circle", size: 26, avatars: avatars)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.author)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                    if let verdict = entry.verdict {
                        Text(verdict.text)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(verdict.tint)
                    }
                    Spacer(minLength: 0)
                    if entry.isLatest {
                        Circle().fill(Palette.green).frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    Text(entry.when)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                Blocks(blocks: entry.blocks)
                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 5) {
                        if let path = note.path {
                            Label {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            } icon: {
                                Image(systemName: "doc.text").font(.system(size: 10))
                            }
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Palette.secondary)
                        }
                        Blocks(blocks: note.blocks)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                }
            }
        }
        .padding(10)
        .modifier(Hoverable(pointer: pointer, radius: 12))
        .onTapGesture { open(entry.url) }
    }
}

/// A comment's paragraphs, quotes and code, in reading sizes.
private struct Blocks: View {
    let blocks: [TextBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.primary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let text):
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.tertiary).frame(width: 2)
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let code, let label):
                    VStack(alignment: .leading, spacing: 5) {
                        if let label {
                            Text(label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.green)
                        }
                        Text(code)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Palette.primary.opacity(0.9))
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                case .truncated:
                    Text("Continues on GitHub")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}

/// Two weeks of contributions as bars, with the streak and how this week compares.
private struct ActivityView: View {
    let activity: DetailModel.Activity

    @Environment(\.notchIsStatic) private var isStatic
    @State private var revealed = false

    var body: some View {
        let peak = max(activity.days.map(\.count).max() ?? 0, 1)
        let thisWeek = activity.days.suffix(7).map(\.date)
        let today = activity.days.last

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(activity.days, id: \.date) { day in
                    let isRecent = thisWeek.contains(day.date)
                    VStack(spacing: 5) {
                        Text(day.count > 0 ? "\(day.count)" : " ")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(day == today ? Palette.primary : Palette.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(day.count == 0
                                ? Color.white.opacity(0.1)
                                : Palette.green.opacity(isRecent ? 1 : 0.4))
                            .frame(height: day.count == 0 ? 3 : max(4, 64 * CGFloat(day.count) / CGFloat(peak)))
                            .scaleEffect(y: revealed || isStatic ? 1 : 0.01, anchor: .bottom)
                        Text(Self.weekday(day.date, .narrow))
                            .font(.system(size: 10, weight: day == today ? .semibold : .regular))
                            .foregroundStyle(day == today ? Palette.primary : Palette.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 100, alignment: .bottom)

            VStack(alignment: .leading, spacing: 7) {
                streak
                comparison
                if let busiest = activity.days.max(by: { $0.count < $1.count }), busiest.count > 0 {
                    Fact(symbol: "star.fill", tint: Palette.secondary) {
                        Text("Busiest: \(Self.weekday(busiest.date, .wide)), \(busiest.count) contribution\(busiest.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .onAppear {
            withAnimation(Motion.chartReveal) { revealed = true }
        }
    }

    @ViewBuilder
    private var streak: some View {
        let today = activity.days.last?.count ?? 0
        if activity.streak > 0 {
            Fact(symbol: "flame.fill", tint: Palette.amber) {
                if today == 0 {
                    Text("\(activity.streak)-day streak, nothing yet today")
                } else {
                    Text("\(activity.streak)-day streak")
                }
            }
        } else {
            Fact(symbol: "flame", tint: Palette.tertiary) {
                Text("No streak going")
            }
        }
    }

    @ViewBuilder
    private var comparison: some View {
        let delta = activity.thisWeek - activity.lastWeek
        if delta > 0 {
            Fact(symbol: "arrow.up.right", tint: Palette.green) {
                Text("\(activity.thisWeek) this week, up from \(activity.lastWeek)")
            }
        } else if delta < 0 {
            Fact(symbol: "arrow.down.right", tint: Palette.secondary) {
                Text("\(activity.thisWeek) this week, down from \(activity.lastWeek)")
            }
        } else {
            Fact(symbol: "equal", tint: Palette.secondary) {
                Text("\(activity.thisWeek) this week, same as the week before")
            }
        }
    }

    /// Contribution days are calendar dates, stored as midnight UTC.
    private static func weekday(_ date: Date, _ width: Date.FormatStyle.Symbol.Weekday) -> String {
        var style = Date.FormatStyle().weekday(width)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

private struct Fact<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            content
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.primary)
        }
    }
}

private struct Avatar: View {
    let url: URL?
    let fallback: String
    let size: CGFloat
    let avatars: AvatarCache

    var body: some View {
        Group {
            if let url, let image = avatars.images[url] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// Lights up a row under the pointer, so it reads as something to click.
private struct Hoverable: ViewModifier {
    let pointer: DetailPointer
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    let hovered = pointer.location.map { geometry.frame(in: .named(DetailPointer.space)).contains($0) } ?? false
                    shape
                        .fill(Color.white.opacity(hovered ? 0.08 : 0))
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
            }
            .contentShape(shape)
    }
}
