import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats at Dock level on every Space.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Allowed over full-screen apps so it can come out with the Dock there. The app
        // keeps it hidden whenever the Dock is.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Follows the pointer while it's over a view. AppKit only sends mouseMoved to the active
/// app, and Dock Notch rarely is, so this listens to moves system-wide in the meantime.
@MainActor
final class PointerWatch {
    private var monitors: [Any] = []

    func start(_ onMove: @escaping () -> Void) {
        stop()
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { _ in
            MainActor.assumeIsolated { onMove() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { event in
            MainActor.assumeIsolated { onMove() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Hosts the SwiftUI notch and handles the input SwiftUI can't see reliably in a
/// non-activating panel: hover while the app is inactive, first clicks, scrolling,
/// and the right-click menu.
final class NotchHostingView: NSHostingView<NotchView> {
    private let store: NotchStore
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0
    private var scrolledThisGesture = false
    var contextMenu: NSMenu?
    /// Whether the pointer is on the strip, and which box it's over (nil in the gaps).
    var onPointerChange: ((_ inside: Bool, _ box: StripBox?) -> Void)?
    var onClick: (() -> Void)?
    private let pointerWatch = PointerWatch()

    init(store: NotchStore) {
        self.store = store
        super.init(rootView: NotchView(store: store))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: NotchView) { fatalError("init(rootView:) is not supported") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let pill = bounds.insetBy(dx: notchShadowPadding, dy: notchShadowPadding)
        let area = NSTrackingArea(rect: pill, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerWatch.start { [weak self] in self?.reportPointer() }
        reportPointer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerWatch.stop()
        onPointerChange?(false, nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }

    private func reportPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let strip = bounds.insetBy(dx: notchShadowPadding, dy: notchShadowPadding)
        let inside = strip.contains(point)
        let box = inside ? StripLayout(width: strip.width, height: strip.height).box(at: point.x - strip.minX) : nil
        onPointerChange?(inside, box)
    }

    /// One card per scroll gesture, in either direction. Momentum is ignored.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.isEmpty && !event.hasPreciseScrollingDeltas {
            scrollAccumulator = 0
            scrolledThisGesture = false
        }
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        scrollAccumulator += delta
        if !scrolledThisGesture, abs(scrollAccumulator) > (event.hasPreciseScrollingDeltas ? 14 : 0.5) {
            store.step(scrollAccumulator > 0 ? -1 : 1)
            scrolledThisGesture = event.hasPreciseScrollingDeltas
            scrollAccumulator = 0
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }
}
