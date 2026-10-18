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
        // Not .fullScreenAuxiliary: like the Dock, the notch stays out of full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
        store.setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        store.setHovering(false)
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
