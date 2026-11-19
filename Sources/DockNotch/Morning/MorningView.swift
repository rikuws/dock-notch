import AppKit
import SwiftUI

enum MorningMetrics {
    static let width: CGFloat = 680
    static let maxHeight: CGFloat = 860
}

/// The morning window: a greeting, the filter chips, then every provider's sections stacked
/// in one scrolling card, in the popover's style.
struct MorningView: View {
    let date: Date
    let filters: [String]
    let selectedFilter: String
    let sections: [MorningSection]
    let isLoading: Bool
    let selection: String?
    let avatars: AvatarCache
    let pointer: DetailPointer
    let selectFilter: (String) -> Void
    let editFilters: () -> Void
    let open: (URL) -> Void

    static var empty: MorningView {
        MorningView(date: .now, filters: [], selectedFilter: "", sections: [], isLoading: false, selection: nil,
                    avatars: AvatarCache(), pointer: DetailPointer(), selectFilter: { _ in }, editFilters: {}, open: { _ in })
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DetailMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ViewThatFits(in: .vertical) {
                content
                ScrollViewReader { proxy in
                    ScrollView { content }
                        .scrollIndicators(.never)
                        .onChange(of: selection) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                        }
                }
            }
        }
        .frame(width: MorningMetrics.width, alignment: .leading)
        .environment(\.detailSelection, selection)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                Text(Self.greeting(at: date))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.primary)
            }
            Spacer(minLength: 0)
            Text(isLoading ? "Updating…" : date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(filters, id: \.self) { name in
                MorningChip(title: name, isSelected: name == selectedFilter, pointer: pointer) { selectFilter(name) }
            }
            Spacer(minLength: 0)
            MorningChip(title: "Edit Filters…", isSelected: false, pointer: pointer, action: editFilters)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeading(section)
                    if let note = section.note, section.rows.isEmpty {
                        Text(note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(section.rows) { row in
                            RowView(row: row, avatars: avatars, pointer: pointer, open: open)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func sectionHeading(_ section: MorningSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.primary)
            if let trailing = section.trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { section.url.map(open) }
    }

    static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct MorningChip: View {
    let title: String
    let isSelected: Bool
    let pointer: DetailPointer
    let action: () -> Void

    var body: some View {
        let shape = Capsule(style: .continuous)
        Text(title)
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Palette.primary : Palette.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                GeometryReader { geometry in
                    let hovered = pointer.location.map { geometry.frame(in: .named(DetailPointer.space)).contains($0) } ?? false
                    shape.fill(Color.white.opacity(isSelected ? 0.12 : hovered ? 0.06 : 0))
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
            }
            .contentShape(shape)
            .onTapGesture(perform: action)
    }
}

/// Feeds the pointer to SwiftUI for row and chip highlights, as the section window's host does.
final class MorningHostingView: NSHostingView<MorningView> {
    private let pointer: DetailPointer
    private var trackingArea: NSTrackingArea?
    private let pointerWatch = PointerWatch()

    @MainActor
    init(pointer: DetailPointer) {
        self.pointer = pointer
        super.init(rootView: .empty)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: MorningView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let card = bounds.insetBy(dx: notchShadowPadding, dy: notchShadowPadding)
        let area = NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerWatch.start { [weak self] in self?.trackPointer() }
        trackPointer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerWatch.stop()
        pointer.location = nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        trackPointer()
    }

    func stopFollowingPointer() {
        pointerWatch.stop()
    }

    private func trackPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        pointer.location = isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }
}
