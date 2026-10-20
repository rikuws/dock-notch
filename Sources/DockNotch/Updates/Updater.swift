import AppKit
import Sparkle

/// Keeps Dock Notch current, in the way that suits where this copy came from: a release
/// replaces itself with the next signed release; a build from source rebuilds itself
/// from the next release's source with your changes on top.
@MainActor
final class Updater {
    let build = BuildInfo.current
    private lazy var release = ReleaseUpdater()
    private lazy var source = SourceUpdater(build: build)

    func start() {
        switch build.channel {
        case .release: release.start()
        case .source: source.start()
        }
    }

    /// The menu item's title, or nil when this build can't update itself.
    var menuTitle: String? {
        switch build.channel {
        case .release:
            return "Check for Updates…"
        case .source:
            guard source.canUpdate else { return nil }
            return source.available.map { "Update to \($0.dropFirst())…" } ?? "Check for Updates…"
        }
    }

    func checkForUpdates() {
        switch build.channel {
        case .release: release.check()
        case .source: Task { await source.check(userInitiated: true) }
        }
    }
}

/// Sparkle, reading the appcast published with each GitHub release (see RELEASING.md).
@MainActor
private final class ReleaseUpdater: NSObject {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    func start() {
        controller.startUpdater()
    }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension ReleaseUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Dock Notch has no windows to come forward with, so Sparkle's alert would open
    /// behind whatever you're doing. Bring it to the front.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate { NSApp.activate() }
    }
}
