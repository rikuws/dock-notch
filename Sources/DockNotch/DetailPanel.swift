import AppKit
import Observation
import SwiftUI

/// Opens a popover with the detail behind the box under the pointer. It waits a beat so
/// passing over the strip doesn't flash it, then follows the pointer from box to box
/// without waiting. While the pointer is on the strip or its popover, the strip holds still.
@MainActor
final class DetailController {
    /// Called when the pointer arrives on the strip or popover, and when it finally leaves both.
    var onEngagedChange: (() -> Void)?
    private(set) var isEngaged = false

    private let store: NotchStore
    private let panel = NotchPanel()
    private let pointer = DetailPointer()
    private lazy var hostingView = DetailHostingView(pointer: pointer)
    /// Lays out the same view off screen to learn how big the popover should be.
    private let measure = NSHostingController(rootView: DetailView(model: nil, avatars: AvatarCache(), pointer: DetailPointer(), open: { _ in }))

    /// The strip window's frame and its screen, kept current by the app delegate.
    private var stripFrame = NSRect.zero
    private var screenFrame = NSRect.zero

    private var inStrip = false
    private var hovered: StripBox?
    private var inPopover = false
    private var shown: StripBox?
    /// A box that was just clicked: its popover stays shut until the pointer moves on.
    private var dismissed: StripBox?
    private var timer: Task<Void, Never>?
    private var observation = 0

    init(store: NotchStore) {
        self.store = store
        panel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        panel.contentView = hostingView
        hostingView.onHoverChange = { [weak self] inside in
            self?.inPopover = inside
            self?.schedule()
        }
    }

    func stripMoved(to frame: NSRect, screen: NSRect) {
        stripFrame = frame
        screenFrame = screen
        if let shown { show(shown) }
    }

    func stripPointerChanged(inside: Bool, box: StripBox?) {
        guard inside != inStrip || box != hovered else { return }
        inStrip = inside
        if box != hovered {
            hovered = box
            if box != dismissed { dismissed = nil }
        }
        schedule()
    }

    /// Shuts the popover after a click, until the pointer moves to another box.
    func dismiss() {
        dismissed = hovered
        close()
    }

    func close() {
        timer?.cancel()
        timer = nil
        if shown != nil {
            shown = nil
            inPopover = false
            pointer.location = nil
            hostingView.stopFollowingPointer()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.shown == nil else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
        updateEngaged()
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        if let hovered, hovered != dismissed {
            if shown == nil {
                after(.milliseconds(350)) { $0.show(hovered) }
            } else if hovered != shown {
                show(hovered)
            }
        } else if shown != nil, !inPopover {
            // Room to cross the gap between the strip and the popover.
            after(.milliseconds(250)) { $0.close() }
        }
        updateEngaged()
    }

    private func after(_ delay: Duration, _ action: @escaping (DetailController) -> Void) {
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func show(_ box: StripBox) {
        guard let model = DetailModel.make(for: box, store: store), let anchor = anchor(for: box) else {
            // Nothing more to say about this box.
            if shown != nil { close() }
            return
        }
        let opening = shown == nil
        shown = box
        render(model, anchor: anchor, opening: opening)
        observe(box)
        updateEngaged()
    }

    private func render(_ model: DetailModel, anchor: NSRect, opening: Bool) {
        let padding = notchShadowPadding
        let visible = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
        let roomAbove = visible.maxY - anchor.maxY - DetailMetrics.gap - 8
        let roomBelow = anchor.minY - visible.minY - DetailMetrics.gap - 8
        let above = roomAbove >= min(DetailMetrics.maxHeight, 240) || roomAbove >= roomBelow
        let maxHeight = min(DetailMetrics.maxHeight, max(above ? roomAbove : roomBelow, 120))

        let view = DetailView(
            model: model,
            avatars: store.avatars,
            pointer: pointer,
            open: { [weak self] url in self?.open(url) }
        )
        hostingView.rootView = view
        measure.rootView = view
        let fitting = measure.sizeThatFits(in: CGSize(
            width: DetailMetrics.width + padding * 2,
            height: maxHeight + padding * 2
        ))
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))

        let y = above
            ? anchor.maxY + DetailMetrics.gap - padding
            : anchor.minY - DetailMetrics.gap - size.height + padding
        var frame = NSRect(x: anchor.midX - size.width / 2, y: y, width: size.width, height: size.height)
        // Keep the card itself, not its shadow, 8pt inside the screen.
        frame.origin.x = min(max(frame.minX, visible.minX + 8 - padding), visible.maxX - 8 + padding - frame.width)

        if opening {
            panel.setFrame(frame.offsetBy(dx: 0, dy: above ? -6 : 6), display: true)
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
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

    /// Re-renders when what the popover shows changes, such as scrolling the card to another.
    private func observe(_ box: StripBox) {
        observation += 1
        let generation = observation
        withObservationTracking {
            _ = DetailModel.make(for: box, store: store)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == generation, let shown = self.shown else { return }
                self.show(shown)
            }
        }
    }

    private func anchor(for box: StripBox) -> NSRect? {
        let strip = stripFrame.insetBy(dx: notchShadowPadding, dy: notchShadowPadding)
        let layout = StripLayout(width: strip.width, height: strip.height)
        guard let span = layout.span(of: box) else { return nil }
        return NSRect(x: strip.minX + span.lowerBound, y: strip.minY, width: span.upperBound - span.lowerBound, height: strip.height)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        dismiss()
    }

    private func updateEngaged() {
        let engaged = inStrip || inPopover || shown != nil
        guard engaged != isEngaged else { return }
        isEngaged = engaged
        store.setHovering(engaged)
        onEngagedChange?()
    }
}

/// Hosts the popover. Reports the pointer to SwiftUI for row highlights, and to the
/// controller so the popover stays open while the pointer is on it.
final class DetailHostingView: NSHostingView<DetailView> {
    var onHoverChange: ((Bool) -> Void)?
    private let pointer: DetailPointer
    private var trackingArea: NSTrackingArea?
    private let pointerWatch = PointerWatch()

    @MainActor
    init(pointer: DetailPointer) {
        self.pointer = pointer
        super.init(rootView: DetailView(model: nil, avatars: AvatarCache(), pointer: pointer, open: { _ in }))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: DetailView) { fatalError("init(rootView:) is not supported") }

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
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerWatch.stop()
        pointer.location = nil
        onHoverChange?(false)
    }

    /// Scrolling moves the rows under a still pointer.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        trackPointer()
    }

    /// The popover is closing, so the exit event may never come.
    func stopFollowingPointer() {
        pointerWatch.stop()
    }

    private func trackPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        pointer.location = isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }
}
