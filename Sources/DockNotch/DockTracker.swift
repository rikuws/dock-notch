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

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.update()
                let fast = Date.now < self.burstUntil
                try? await Task.sleep(for: fast ? .milliseconds(60) : .seconds(1))
            }
        }
    }

    func requestAccessibility() {
        // The literal value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func burst() {
        burstUntil = .now + 1.5
    }

    private func update() {
        guard let geometry = measure(), geometry != last else { return }
        last = geometry
        onChange(geometry)
    }

    private func measure() -> DockGeometry? {
        if isTrusted, let frame = accessibilityDockFrame() {
            return geometry(forDockFrame: frame)
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

        // An auto-hidden Dock reports a frame just off screen. Keep the notch where
        // the Dock would appear instead of following it out of view.
        switch edge {
        case .bottom where frame.maxY <= screen.frame.minY + 1:
            frame.origin.y = screen.frame.minY + 4
        case .left where frame.maxX <= screen.frame.minX + 1:
            frame.origin.x = screen.frame.minX + 4
        case .right where frame.minX >= screen.frame.maxX - 1:
            frame.origin.x = screen.frame.maxX - frame.width - 4
        default:
            break
        }

        return DockGeometry(frame: frame, screenFrame: screen.frame, edge: edge, isMeasured: true)
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
                let frame = CGRect(x: full.midX, y: full.minY, width: 0, height: bottom)
                return DockGeometry(frame: frame, screenFrame: full, edge: .bottom, isMeasured: false)
            }
            if left > 0 {
                let frame = CGRect(x: full.minX, y: full.minY + 40, width: left, height: 0)
                return DockGeometry(frame: frame, screenFrame: full, edge: .left, isMeasured: false)
            }
            if right > 0 {
                let frame = CGRect(x: full.maxX - right, y: full.minY + 40, width: right, height: 0)
                return DockGeometry(frame: frame, screenFrame: full, edge: .right, isMeasured: false)
            }
        }

        // Auto-hidden Dock: sit at the bottom of the main screen.
        guard let screen = NSScreen.screens.first else { return nil }
        let frame = CGRect(x: screen.frame.midX, y: screen.frame.minY + 4, width: 0, height: 84)
        return DockGeometry(frame: frame, screenFrame: screen.frame, edge: .bottom, isMeasured: false)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
