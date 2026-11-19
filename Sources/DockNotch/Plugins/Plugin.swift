import Foundation

/// A plugin: a folder in `~/Library/Application Support/Dock Notch/Plugins/` with a
/// `plugin.json` and a command that prints sections as JSON. Plugins live outside the app,
/// so updates never touch them, and the JSON is the whole contract between the two. See
/// PLUGINS.md.
struct Plugin: Equatable, Sendable {
    /// The folder's name.
    let id: String
    let folder: URL
    let manifest: Manifest

    struct Manifest: Decodable, Equatable, Sendable {
        let name: String
        /// Run with `/bin/sh -c` in the plugin's folder, like `./mail.sh` or
        /// `osascript mail.applescript`.
        let command: String
        /// Where its sections go in the morning window. The calendar is 10, review requests
        /// 20, your pull requests 30. Default 50.
        var order: Int?
        /// Seconds before the command is stopped. Default 30.
        var timeout: Double?
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dock Notch/Plugins", isDirectory: true)
    }

    /// Every folder in the plugins folder with a readable `plugin.json`, by name. A
    /// manifest that doesn't parse comes back as an error, so the window can say so.
    static func discover() -> [Result<Plugin, PluginError>] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { folder in
                let id = folder.lastPathComponent
                let file = folder.appendingPathComponent("plugin.json")
                guard let data = try? Data(contentsOf: file) else { return nil }
                do {
                    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                    return .success(Plugin(id: id, folder: folder, manifest: manifest))
                } catch {
                    return .failure(PluginError(plugin: id, message: "plugin.json: \(Self.describe(error))"))
                }
            }
    }

    /// Runs the command and parses what it prints.
    func run() async -> Result<Output, PluginError> {
        let result: ProcessResult
        do {
            result = try await PluginProcess.run(
                manifest.command, in: folder, timeout: manifest.timeout ?? 30,
                environment: ["DOCKNOTCH_PLUGIN": id, "DOCKNOTCH_PLUGIN_DIR": folder.path]
            )
        } catch {
            return .failure(PluginError(plugin: id, message: error.localizedDescription))
        }
        guard result.status == 0 else {
            let detail = result.stderrText.split(separator: "\n").last.map(String.init) ?? ""
            return .failure(PluginError(plugin: id, message: "Exited with \(result.status)" + (detail.isEmpty ? "" : ": \(detail)")))
        }
        do {
            return .success(try JSONDecoder().decode(Output.self, from: result.stdout))
        } catch {
            return .failure(PluginError(plugin: id, message: "Its output isn't valid: \(Self.describe(error))"))
        }
    }

    /// What a plugin prints.
    struct Output: Decodable, Sendable {
        let sections: [Section]

        struct Section: Decodable, Sendable {
            var id: String?
            let title: String
            /// A count or short note beside the title, like "3".
            var trailing: String?
            /// Opened by clicking the title.
            var url: String?
            /// Shown when there are no rows, like "Inbox zero".
            var note: String?
            var order: Int?
            var rows: [Row]?
        }

        struct Row: Decodable, Sendable {
            var id: String?
            let title: String
            /// The colored start of the second line, like a sender or a time.
            var lead: String?
            /// green, red, amber, blue, primary, secondary (the default) or tertiary.
            var leadTint: String?
            /// The rest of the second line, in gray, after the lead.
            var detail: String?
            /// An SF Symbol name for the row's icon, like "envelope.fill".
            var symbol: String?
            var tint: String?
            /// An image URL for a round avatar instead of a symbol.
            var avatar: String?
            /// Opened by clicking the row.
            var url: String?
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "missing \"\(key.stringValue)\"" + path(context.codingPath)
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "wrong type" + path(context.codingPath)
        case DecodingError.dataCorrupted(let context):
            context.codingPath.isEmpty ? "not JSON" : "bad value" + path(context.codingPath)
        default:
            error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "" : " at " + keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

struct PluginError: Error, Equatable, Sendable {
    let plugin: String
    let message: String
}

/// Runs a plugin's command with `/bin/sh -c`, with a PATH that includes Homebrew's, and
/// stops it after `timeout` seconds.
enum PluginProcess {
    struct TimedOut: LocalizedError {
        let seconds: Double
        var errorDescription: String? { "Took longer than \(Int(seconds)) seconds" }
    }

    static func run(_ command: String, in folder: URL, timeout: Double, environment extra: [String: String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = folder
                var env = ProcessInfo.processInfo.environment
                let inherited = env["PATH"]?.split(separator: ":").map(String.init) ?? []
                var seen = Set<String>()
                env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + inherited)
                    .filter { seen.insert($0).inserted }.joined(separator: ":")
                env.merge(extra) { $1 }
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timedOut = TimeoutFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
                let errors = Drain(stderr.fileHandleForReading)
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if timedOut.isSet {
                    continuation.resume(throwing: TimedOut(seconds: timeout))
                } else {
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: output, stderr: errors.wait()))
                }
            }
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private final class Drain: @unchecked Sendable {
        private let group = DispatchGroup()
        private var data = Data()

        init(_ handle: FileHandle) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                self.data = handle.readDataToEndOfFile()
                self.group.leave()
            }
        }

        func wait() -> Data {
            group.wait()
            return data
        }
    }
}
