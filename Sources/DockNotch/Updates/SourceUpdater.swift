import AppKit

/// Keeps a build from source current. It watches the upstream repository's releases and,
/// when a newer one is out, offers to run `make update` in the checkout. That moves your
/// changes onto the new release, asking your coding agent to carry over any that clash,
/// then rebuilds and relaunches (see CUSTOMIZING.md).
@MainActor
final class SourceUpdater {
    private let build: BuildInfo
    /// The newer release's tag, like "v0.3.0", once one has been seen.
    private(set) var available: String?
    private var loop: Task<Void, Never>?

    init(build: BuildInfo) {
        self.build = build
    }

    /// Only a build that knows its checkout can rebuild itself.
    var canUpdate: Bool {
        guard let directory = build.sourceDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("Makefile").path)
    }

    func start() {
        guard canUpdate else { return }
        loop = Task { [weak self] in
            // Give launch a moment, then look a few times a day.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(6 * 3_600))
            }
        }
    }

    func check(userInitiated: Bool) async {
        let latest: String
        do {
            latest = try await latestRelease()
        } catch {
            if userInitiated { inform("Couldn’t check for updates", error.localizedDescription) }
            return
        }

        guard build.isOlder(than: latest) else {
            available = nil
            if userInitiated {
                inform("You’re up to date", "\(build.title) is built on the newest release, \(latest).")
            }
            return
        }
        available = latest
        // A scheduled check asks once per release; the menu item stays until you update.
        if userInitiated || Settings.offeredSourceUpdate != latest {
            Settings.offeredSourceUpdate = latest
            offer(latest)
        }
    }

    private func latestRelease() async throws -> String {
        struct Release: Decodable { let tag_name: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(build.upstream)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubError.failed("\(build.upstream) has no releases yet.")
        }
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }

    private func offer(_ tag: String) {
        guard let directory = build.sourceDirectory else { return }
        let changes = build.changes == 0
            ? "Your build"
            : "Your \(build.changes) change\(build.changes == 1 ? "" : "s")"
        let alert = NSAlert()
        alert.messageText = "Dock Notch \(tag.dropFirst()) is out"
        alert.informativeText = """
            \(changes) on \(build.version) will move onto \(tag) in \(directory.path), \
            then Dock Notch rebuilds and relaunches. If a change clashes with the new release, \
            your coding agent is asked to carry it over.
            """
        alert.addButton(withTitle: "Update in Terminal")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            runUpdate(in: directory)
        }
    }

    /// Opens `make update` in your terminal app, where you can follow it and talk to the
    /// agent if it's needed. The new build installs where this one runs from.
    private func runUpdate(in directory: URL) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Update Dock Notch.command")
        let contents = """
            #!/bin/zsh -l
            cd \(quoted(directory.path)) && make update INSTALL_PATH=\(quoted(Bundle.main.bundlePath))

            """
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            inform("Couldn’t start the update", error.localizedDescription)
        }
    }

    private func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
