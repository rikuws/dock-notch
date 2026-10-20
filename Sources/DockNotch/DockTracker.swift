import AppKit
import ApplicationServices

struct DockGeometry: Equatable {
    enum Edge { case bottom, left, right }

    /// The Dock's frame in Cocoa screen coordinates (origin bottom-left).
    var frame: CGRect
    var screenFrame: CGRect
    var edge: Edge
    /// False when the frame is a guess because Accessibility access isn't granted.
    var isMeasured: Bool
    /// False while the Dock is out of view: auto-hidden, or behind a full-screen app.
    /// `frame` is then where it will appear.
    var isVisible: Bool

    var thickness: CGFloat { edge == .bottom ? frame.height : frame.width }
}

/// Follows the Dock's size and position. The exact frame comes from the Dock's
/// accessibility tree; without that permission it falls back to the screen's
/// reserved Dock area.
@MainActor
final class DockTracker {
    private let onChange: (DockGeometry) -> Void
    private var last: DockGeometry?
    private var loop: Task<Void, Never>?
    private var pointerMonitor: Any?
    private var burstUntil = Date.distantPast
    private var dockPID: pid_t = 0
    private var dockElement: AXUIElement?

    init(onChange: @escaping (DockGeometry) -> Void) {
        self.onChange = onChange
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        if !isTrusted && !Settings.didPromptForAccessibility {
            Settings.didPromptForAccessibility = true
            requestAccessibility()
        }

        // The Dock resizes with an animation when apps launch or quit, so poll
        // quickly for a moment after those events to follow it smoothly.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.burst() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.burst() }
        }

        // A hidden Dock slides in when the pointer reaches its edge, and away again
        // once the pointer leaves. Poll quickly while that can happen.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPointerNearHidingDock() else { return }
                self.burst()
            }
        }

        poll()
    }

    func requestAccessibility() {
        // The literal value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func burst() {
        let polling = Date.now < burstUntil
        burstUntil = .now + 1.5
        // Measure now rather than waiting out the slow interval.
        if !polling { poll() }
    }

    /// Measures now, then every 60 ms during a burst and every second otherwise.
    /// A hidden Dock is checked every 250 ms: nothing announces it coming back when
    /// a full-screen app closes.
    private func poll() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.update()
                let interval: Duration = if Date.now < self.burstUntil {
                    .milliseconds(60)
                } else if let last = self.last, last.isMeasured, !last.isVisible {
                    .milliseconds(250)
                } else {
                    .seconds(1)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Whether the pointer is near the Dock's edge of a screen that doesn't reserve
    /// room for the Dock, where an auto-hiding Dock comes and goes.
    private func isPointerNearHidingDock() -> Bool {
        guard let dock = last, dock.isMeasured else { return false }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.minX <= point.x && point.x <= $0.frame.maxX && $0.frame.minY <= point.y && point.y <= $0.frame.maxY
        }) else { return false }
        let full = screen.frame
        let visible = screen.visibleFrame
        let reach = dock.thickness + 40
        switch dock.edge {
        case .bottom:
            return visible.minY - full.minY < dock.thickness / 2 && point.y < full.minY + reach
        case .left:
            return visible.minX - full.minX < dock.thickness / 2 && point.x < full.minX + reach
        case .right:
            return full.maxX - visible.maxX < dock.thickness / 2 && point.x > full.maxX - reach
        }
    }

    private func update() {
        guard let geometry = measure(), geometry != last else { return }
        last = geometry
        onChange(geometry)
    }

    private func measure() -> DockGeometry? {
        if isTrusted {
            if let frame = accessibilityDockFrame() {
                return geometry(forDockFrame: frame)
            }
            // The Dock briefly stops answering while it removes a quitting app's icon.
            // Keep the last frame rather than jumping to the estimate.
            if last?.isMeasured == true { return nil }
        }
        return estimate()
    }

    private func geometry(forDockFrame dockFrame: CGRect) -> DockGeometry? {
        var frame = dockFrame
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.intersects(frame) }
            ?? screens.first { $0.frame.minX <= frame.midX && frame.midX <= $0.frame.maxX }
            ?? NSScreen.main
        guard let screen else { return nil }

        let edge: DockGeometry.Edge = frame.width >= frame.height
            ? .bottom
            : (frame.midX < screen.frame.midX ? .left : .right)

        // A hidden Dock, whether auto-hidden or behind a full-screen app, slides off
        // screen. Past halfway, count it as hidden and report where it will appear.
        var isVisible = false
        switch edge {
        case .bottom where frame.midY <= screen.frame.minY:
            frame.origin.y = screen.frame.minY + 6
        case .bottom:
            isVisible = true
            // On macOS 26 the accessibility frame sits about 4.5pt above the glass you
            // actually see. The area the screen reserves for the Dock ends at the glass's
            // top edge, so align to that instead.
            if #available(macOS 26, *), screen.visibleFrame.minY > screen.frame.minY {
                frame.origin.y = screen.visibleFrame.minY - frame.height
            }
        case .left where frame.midX <= screen.frame.minX:
            frame.origin.x = screen.frame.minX + 4
        case .right where frame.midX >= screen.frame.maxX:
            frame.origin.x = screen.frame.maxX - frame.width - 4
        default:
            isVisible = true
        }

        return DockGeometry(frame: frame, screenFrame: screen.frame, edge: edge, isMeasured: true, isVisible: isVisible)
    }

    private func accessibilityDockFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        if dock.processIdentifier != dockPID || dockElement == nil {
            dockPID = dock.processIdentifier
            let element = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(element, 0.25)
            dockElement = element
        }
        guard let app = dockElement else { return nil }

        let children: [AXUIElement] = attribute(app, kAXChildrenAttribute) ?? []
        for child in children where (attribute(child, kAXRoleAttribute) as String?) == kAXListRole {
            guard let positionValue: AXValue = attribute(child, kAXPositionAttribute),
                  let sizeValue: AXValue = attribute(child, kAXSizeAttribute) else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue, .cgPoint, &position)
            AXValueGetValue(sizeValue, .cgSize, &size)
            guard size.width > 0, size.height > 0 else { continue }

            // Accessibility uses a top-left origin anchored to the primary screen.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
        }
        return nil
    }

    /// Without Accessibility access the Dock's width is unknown, but the strip it
    /// reserves on screen still tells us which edge it's on and how thick it is.
    private func estimate() -> DockGeometry? {
        for screen in NSScreen.screens {
            let full = screen.frame
            let visible = screen.visibleFrame
            let bottom = visible.minY - full.minY
            let left = visible.minX - full.minX
            let right = full.maxX - visible.maxX

            if bottom > 0 {
                // On macOS 26 a 90pt reserved strip holds an 84pt Dock whose glass ends at
                // the strip's top edge, about 6pt above the screen edge.
                let frame = CGRect(x: full.midX, y: full.minY + 6, width: 0, height: max(bottom - 6, 1))
                return DockGeometry(frame: frame, screenFrame: full, edge: .bottom, isMeasured: false, isVisible: true)
            }
            if left > 0 {
                let frame = CGRect(x: full.minX, y: full.minY + 40, width: left, height: 0)
                return DockGeometry(frame: frame, screenFrame: full, edge: .left, isMeasured: false, isVisible: true)
            }
            if right > 0 {
                let frame = CGRect(x: full.maxX - right, y: full.minY + 40, width: right, height: 0)
                return DockGeometry(frame: frame, screenFrame: full, edge: .right, isMeasured: false, isVisible: true)
            }
        }

        // No screen reserves room for the Dock. With auto-hide off, that means a
        // full-screen app covers it. An auto-hidden Dock can't be followed without
        // Accessibility, so sit at the bottom of the main screen.
        guard let screen = NSScreen.screens.first else { return nil }
        let frame = CGRect(x: screen.frame.midX, y: screen.frame.minY + 6, width: 0, height: 84)
        let autohides = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
        return DockGeometry(frame: frame, screenFrame: screen.frame, edge: .bottom, isMeasured: false, isVisible: autohides)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
