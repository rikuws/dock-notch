import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NotchStore()
    private let panel = NotchPanel()
    private lazy var hostingView = NotchHostingView(store: store)
    private lazy var tracker = DockTracker { [weak self] geometry in self?.place(for: geometry) }
    private var hasPlaced = false

    private let gap: CGFloat = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        hostingView.contextMenu = makeMenu()
        panel.contentView = hostingView
        tracker.start()
        store.start()
    }

    // MARK: - Placement

    private func place(for dock: DockGeometry) {
        let width = Settings.pillWidth
        let height = min(80, max(54, dock.thickness - 14))
        let inset = (dock.thickness - height) / 2
        let screen = dock.screenFrame

        var pill: CGRect
        switch dock.edge {
        case .bottom:
            let x = dock.isMeasured ? dock.frame.maxX + gap : screen.maxX - width - 16
            pill = CGRect(x: x, y: dock.frame.midY - height / 2, width: width, height: height)
        case .left:
            pill = CGRect(x: dock.frame.minX + inset, y: dock.frame.minY - gap - height, width: width, height: height)
        case .right:
            pill = CGRect(x: dock.frame.maxX - inset - width, y: dock.frame.minY - gap - height, width: width, height: height)
        }
        // Stay on the Dock's screen even when the Dock is very wide.
        pill.origin.x = min(max(pill.minX, screen.minX + 8), screen.maxX - width - 8)
        pill.origin.y = max(pill.minY, screen.minY + 4)

        store.pillSize = pill.size
        let frame = pill.insetBy(dx: -notchShadowPadding, dy: -notchShadowPadding)

        if hasPlaced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            hasPlaced = true
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
        Task { await store.refresh() }
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
