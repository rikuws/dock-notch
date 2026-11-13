import AppKit
import Observation
import SwiftUI

/// A larger card in the middle of the screen with the whole of one section, such as every
/// pull request waiting for your review, that stays until you close it. Opened from a
/// `docknotch://` link or the right-click menu.
///
/// Keys: ← → (or Tab) switch sections, 1–6 jump to one, ↑ ↓ pick a row, ↩ opens it,
/// ⌘R refreshes, Esc closes. Clicking anywhere else closes it too.
@MainActor
final class SectionController {
    private let store: NotchStore
    private let panel = SectionPanel()
    private let pointer = DetailPointer()
    private lazy var hostingView = SectionHostingView(pointer: pointer)
    private let measure = NSHostingController(rootView: SectionView.empty)

    private(set) var kind: CardKind?
    private var selection: String?
    private var keyMonitor: Any?
    private var observation = 0
    /// Where the window's top edge sits, kept while its height follows the section.
    private var top: CGFloat?

    var isOpen: Bool { kind != nil }

    init(store: NotchStore) {
        self.store = store
        panel.contentView = hostingView
        panel.onResignKey = { [weak self] in self?.close() }
    }

    /// Opens the window on `kind`, or on what most needs you when nil.
    func show(_ kind: CardKind? = nil) {
        let target = kind ?? defaultKind
        let opening = !isOpen
        if self.kind != target { selection = nil }
        self.kind = target
        store.markSeen(target)
        render(opening: opening)
        observe()
        if opening { startKeys() }
    }

    /// Closes the window if it's already showing `kind` (or anything, when nil), otherwise
    /// opens it there. Handy for a hotkey.
    func toggle(_ kind: CardKind? = nil) {
        if let shown = self.kind, kind == nil || kind == shown {
            close()
        } else {
            show(kind)
        }
    }

    func close() {
        guard isOpen else { return }
        kind = nil
        selection = nil
        top = nil
        observation += 1
        stopKeys()
        hostingView.stopFollowingPointer()
        pointer.location = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Contents

    /// Sections with something to show, in the rotation's order.
    private var sections: [CardKind] {
        guard let snapshot = store.snapshot else { return [] }
        return CardKind.allCases.filter { DetailModel.make(for: $0, snapshot: snapshot, rows: 1) != nil }
    }

    /// News that needs you first, then the card on the strip.
    private var defaultKind: CardKind {
        let available = sections
        let order: [CardKind] = [.reviews, .comment, .checks, .openPRs]
        if let news = order.first(where: { available.contains($0) && store.attention(of: $0).isNew }) {
            return news
        }
        return available.contains(store.current) ? store.current : available.first ?? store.current
    }

    private func model(for kind: CardKind) -> DetailModel? {
        store.snapshot.flatMap { DetailModel.make(for: kind, snapshot: $0, rows: 50) }
    }

    private func makeView() -> SectionView {
        guard let kind else { return .empty }
        let tabs = sections.map { section in
            let attention = store.attention(of: section)
            return SectionView.Tab(kind: section, needsYou: attention.level == .needsYou, isNew: attention.isNew)
        }
        return SectionView(
            kind: kind,
            tabs: tabs,
            model: model(for: kind) ?? Self.placeholder(store.status),
            selection: selection,
            avatars: store.avatars,
            pointer: pointer,
            select: { [weak self] kind in self?.show(kind) },
            open: { [weak self] url in self?.open(url) }
        )
    }

    private static func placeholder(_ status: NotchStore.Status) -> DetailModel {
        let title = switch status {
        case .failed(let error): error.localizedDescription
        case .loading, .ready: "Fetching from GitHub…"
        }
        return DetailModel(id: "placeholder", header: .init(title: title), content: .rows([], more: nil))
    }

    // MARK: - Window

    private func render(opening: Bool) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let padding = notchShadowPadding
        let maxHeight = min(SectionMetrics.maxHeight, visible.height * 0.72)

        let view = makeView()
        hostingView.rootView = view
        measure.rootView = view
        let fitting = measure.sizeThatFits(in: CGSize(
            width: SectionMetrics.width + padding * 2,
            height: maxHeight + padding * 2
        ))
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))

        // Like Spotlight: centered, a little above the middle, growing downwards.
        let top = opening || self.top == nil ? visible.maxY - visible.height * 0.16 + padding : self.top!
        self.top = top
        let frame = NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)

        if opening {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -8), display: true)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Re-renders when the data behind the window changes.
    private func observe() {
        observation += 1
        let generation = observation
        withObservationTracking {
            _ = makeView()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == generation, self.isOpen else { return }
                if let kind = self.kind, !self.sections.contains(kind), let first = self.sections.first {
                    self.kind = first
                    self.selection = nil
                }
                self.render(opening: false)
                self.observe()
            }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }

    // MARK: - Keyboard

    private func startKeys() {
        stopKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.isOpen, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func stopKeys() {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "r": Task { await store.refresh(immediately: true) }; return true
            case "w": close(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 53: close() // Esc
        case 123: switchSection(-1) // ←
        case 124: switchSection(1) // →
        case 48: switchSection(modifiers.contains(.shift) ? -1 : 1) // Tab
        case 125: moveSelection(1) // ↓
        case 126: moveSelection(-1) // ↑
        case 36, 76: openSelection() // Return, Enter
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1 else { return false }
            let available = sections
            guard digit <= available.count else { return false }
            show(available[digit - 1])
        }
        return true
    }

    private func switchSection(_ delta: Int) {
        let available = sections
        guard let kind, !available.isEmpty else { return }
        let index = available.firstIndex(of: kind) ?? 0
        show(available[((index + delta) % available.count + available.count) % available.count])
    }

    private func moveSelection(_ delta: Int) {
        guard let kind, let items = model(for: kind)?.selectable, !items.isEmpty else { return }
        let index = selection.flatMap { id in items.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        selection = items[next].id
        render(opening: false)
    }

    private func openSelection() {
        guard let kind, let model = model(for: kind) else { return }
        let url = selection.flatMap { id in model.selectable.first { $0.id == id }?.url } ?? model.header.url
        url.map(open)
    }
}

enum SectionMetrics {
    static let width: CGFloat = 600
    static let maxHeight: CGFloat = 680
}

extension CardKind {
    /// The name a `docknotch://` link uses for this section, and what it also answers to.
    var linkNames: [String] {
        switch self {
        case .contributions: ["activity", "contributions"]
        case .openPRs: ["prs", "pulls", "pull-requests", "open-prs"]
        case .comment: ["comments", "comment", "conversation"]
        case .reviews: ["reviews", "review", "review-requests"]
        case .checks: ["checks", "ci"]
        case .merged: ["merged", "merges"]
        }
    }

    init?(linkName: String) {
        let name = linkName.lowercased()
        guard let kind = Self.allCases.first(where: { $0.linkNames.contains(name) }) else { return nil }
        self = kind
    }

    var tabTitle: String {
        switch self {
        case .contributions: "Activity"
        case .openPRs: "Pull requests"
        case .comment: "Comments"
        case .reviews: "Reviews"
        case .checks: "Checks"
        case .merged: "Merged"
        }
    }
}

/// The larger card: section tabs above the same header and rows as a popover.
struct SectionView: View {
    struct Tab: Equatable {
        let kind: CardKind
        let needsYou: Bool
        let isNew: Bool
    }

    let kind: CardKind?
    let tabs: [Tab]
    let model: DetailModel?
    let selection: String?
    let avatars: AvatarCache
    let pointer: DetailPointer
    let select: (CardKind) -> Void
    let open: (URL) -> Void

    static var empty: SectionView {
        SectionView(kind: nil, tabs: [], model: nil, selection: nil, avatars: AvatarCache(),
                    pointer: DetailPointer(), select: { _ in }, open: { _ in })
    }

    var body: some View {
        DetailView(
            model: model,
            avatars: avatars,
            pointer: pointer,
            open: open,
            width: SectionMetrics.width,
            top: AnyView(tabBar),
            selection: selection
        )
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.kind) { tab in
                TabButton(tab: tab, isSelected: tab.kind == kind, pointer: pointer) { select(tab.kind) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct TabButton: View {
    let tab: SectionView.Tab
    let isSelected: Bool
    let pointer: DetailPointer
    let action: () -> Void

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 5) {
            Text(tab.kind.tabTitle)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.primary : Palette.secondary)
            if tab.needsYou {
                Circle()
                    .fill(tab.isNew ? Palette.green : Palette.tertiary)
                    .frame(width: 5, height: 5)
            }
        }
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

/// A borderless panel that takes the keyboard without bringing the app forward, and says
/// when it loses it, so a click elsewhere closes it.
final class SectionPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Feeds the pointer to SwiftUI for row and tab highlights, as the popover's host does.
final class SectionHostingView: NSHostingView<SectionView> {
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
    required init(rootView: SectionView) { fatalError("init(rootView:) is not supported") }

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
