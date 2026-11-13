import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NotchStore()
    private let panel = NotchPanel()
    private lazy var hostingView = NotchHostingView(store: store)
    private lazy var tracker = DockTracker { [weak self] geometry in self?.place(for: geometry) }
    private lazy var details = DetailController(store: store)
    private lazy var sections = SectionController(store: store)
    private let updater = Updater()
    private var hasPlaced = false
    private var dock: DockGeometry?
    /// Where the strip sits beside the Dock, and where it slides to when the Dock hides.
    private var shownFrame = NSRect.zero
    private var hiddenFrame = NSRect.zero
    private var isShown = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        handle(url)
    }

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
        updater.start()
    }

    // MARK: - Links

    /// `docknotch://show/reviews` opens the larger window on a section; `toggle/…` closes it
    /// when it's already there, for binding to a hotkey; `close` and `refresh` do what they
    /// say. Leave out the section for whatever most needs you. A bare section name,
    /// `docknotch://reviews`, works like `show`.
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "docknotch" else { return }
        let words = ([url.host(percentEncoded: false)] + url.pathComponents.filter { $0 != "/" })
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        let action = words.first ?? "show"
        let section = words.dropFirst().first.flatMap(CardKind.init(linkName:))

        switch action {
        case "show", "open": sections.show(section)
        case "toggle": sections.toggle(section)
        case "close", "hide": sections.close()
        case "refresh": Task { await store.refresh(immediately: true) }
        default:
            if let kind = CardKind(linkName: action) { sections.show(kind) }
        }
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

        let movedScreen = self.dock.map { $0.screenFrame != dock.screenFrame } ?? false
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
        if movedScreen {
            // Sliding a window from one display to another, especially between Retina
            // and non-Retina ones, can leave it in place but no longer drawn. Take it down
            // and bring it up afresh on the new screen, as when the Dock appears.
            details.close()
            panel.orderOut(nil)
            isShown = false
        } else if isShown && dock.isVisible {
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

    private enum Tag: Int { case accessibility = 1, login, update }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open Window", action: #selector(openWindow), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open GitHub", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let accessibility = menu.addItem(withTitle: "Enable Precise Dock Tracking…", action: #selector(enableAccessibility), keyEquivalent: "")
        accessibility.target = self
        accessibility.tag = Tag.accessibility.rawValue
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.tag = Tag.login.rawValue
        menu.addItem(.separator())
        menu.addItem(withTitle: updater.build.title, action: nil, keyEquivalent: "").isEnabled = false
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.tag = Tag.update.rawValue
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dock Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.accessibility.rawValue)?.isHidden = tracker.isTrusted
        menu.item(withTag: Tag.login.rawValue)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let update = menu.item(withTag: Tag.update.rawValue) {
            update.title = updater.menuTitle ?? ""
            update.isHidden = updater.menuTitle == nil
        }
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func refreshNow() {
        Task { await store.refresh(immediately: true) }
    }

    @objc private func openWindow() {
        details.close()
        sections.show()
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
