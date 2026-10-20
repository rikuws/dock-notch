import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NotchStore()
    private let panel = NotchPanel()
    private lazy var hostingView = NotchHostingView(store: store)
    private lazy var tracker = DockTracker { [weak self] geometry in self?.place(for: geometry) }
    private lazy var details = DetailController(store: store)
    private var hasPlaced = false
    private var dock: DockGeometry?
    /// Where the strip sits beside the Dock, and where it slides to when the Dock hides.
    private var shownFrame = NSRect.zero
    private var hiddenFrame = NSRect.zero
    private var isShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        hostingView.contextMenu = makeMenu()
        hostingView.onPointerChange = { [weak self] inside, box in
            self?.details.stripPointerChanged(inside: inside, box: box)
        }
        hostingView.onClick = { [weak self] in self?.details.dismiss() }
        details.onEngagedChange = { [weak self] in self?.updateVisibility() }
        panel.contentView = hostingView
        tracker.start()
        store.start()
    }

    // MARK: - Placement

    private func place(for dock: DockGeometry) {
        // As tall as the Dock, within limits that keep the text legible.
        let height = min(128, max(60, dock.thickness))
        let inset = (dock.thickness - height) / 2
        let screen = dock.screenFrame
        let scale = height / 84
        let gap = StripLayout.spacing(forHeight: height)

        // The free space beside the Dock that the strip may fill, with `gap` on both ends.
        var region: CGRect
        switch dock.edge {
        case .bottom where dock.isMeasured:
            let minX = dock.frame.maxX + gap
            region = CGRect(x: minX, y: dock.frame.midY - height / 2, width: screen.maxX - gap - minX, height: height)
        case .bottom:
            // Without the Dock's width, take one card's worth at the right edge.
            let width = StripLayout.heroPreferredWidth * scale
            region = CGRect(x: screen.maxX - gap - width, y: dock.frame.midY - height / 2, width: width, height: height)
        case .left:
            let minX = dock.frame.minX + inset
            region = CGRect(x: minX, y: dock.frame.minY - gap - height, width: screen.maxX - gap - minX, height: height)
        case .right:
            let maxX = dock.frame.maxX - inset
            region = CGRect(x: screen.minX + gap, y: dock.frame.minY - gap - height, width: maxX - screen.minX - gap, height: height)
        }
        region.size.width = max(region.width, 300 * scale)

        // The layout may not use all of a very wide region; keep the strip against the Dock.
        let layout = StripLayout(width: region.width, height: height)
        var strip = region
        strip.size.width = layout.totalWidth
        if dock.edge == .right { strip.origin.x = region.maxX - strip.width }

        // Stay on the Dock's screen even when the Dock leaves no room.
        strip.origin.x = min(max(strip.minX, screen.minX + 8), screen.maxX - strip.width - 8)
        strip.origin.y = max(strip.minY, screen.minY + 4)

        let frame = strip.insetBy(dx: -notchShadowPadding, dy: -notchShadowPadding)

        // A hidden strip waits past the screen edge, where the Dock went.
        var hidden = frame
        switch dock.edge {
        case .bottom: hidden.origin.y -= strip.maxY - screen.minY
        case .left: hidden.origin.x -= dock.frame.maxX - screen.minX
        case .right: hidden.origin.x += screen.maxX - dock.frame.minX
        }

        self.dock = dock
        shownFrame = frame
        hiddenFrame = hidden
        details.stripMoved(to: frame, screen: screen)

        if !hasPlaced {
            hasPlaced = true
            isShown = dock.isVisible
            panel.setFrame(isShown ? shownFrame : hiddenFrame, display: true)
            if isShown { panel.orderFrontRegardless() }
            return
        }
        if isShown && dock.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }
        }
        updateVisibility()
    }

    /// Like an extension of the Dock, the strip is only out while the Dock is: it slides
    /// away when the Dock auto-hides or a full-screen app takes the screen. The pointer on
    /// the strip or its popover keeps it out, so it can still be used after an auto-hiding
    /// Dock leaves.
    private func updateVisibility() {
        guard let dock else { return }
        let show = dock.isVisible || details.isEngaged
        guard show != isShown else { return }
        isShown = show

        if show {
            if !panel.isVisible {
                panel.setFrame(hiddenFrame, display: true)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(shownFrame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hiddenFrame, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Menu

    private enum Tag: Int { case accessibility = 1, login }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open GitHub", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let accessibility = menu.addItem(withTitle: "Enable Precise Dock Tracking…", action: #selector(enableAccessibility), keyEquivalent: "")
        accessibility.target = self
        accessibility.tag = Tag.accessibility.rawValue
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.tag = Tag.login.rawValue
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dock Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.accessibility.rawValue)?.isHidden = tracker.isTrusted
        menu.item(withTag: Tag.login.rawValue)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func refreshNow() {
        Task { await store.refresh(immediately: true) }
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/pulls")!)
    }

    @objc private func enableAccessibility() {
        tracker.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
