import Foundation

enum GitHubError: LocalizedError, Equatable {
    case ghNotFound
    case notAuthenticated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound: "The GitHub CLI (gh) was not found."
        case .notAuthenticated: "gh is not signed in."
        case .failed(let message): message
        }
    }
}

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the `gh` binary. GUI apps don't inherit the shell's PATH, so the binary
/// is located explicitly and its directory is put on PATH for the child process.
struct GHRunner: Sendable {
    let executable: URL

    static func locate() -> GHRunner? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/run/current-system/sw/bin/gh",
            "\(home)/.nix-profile/bin/gh",
            "\(home)/.local/bin/gh",
            "/usr/bin/gh",
        ]
        if let custom = Settings.ghPath { candidates.insert(custom, at: 0) }

        if let hit = candidates.first(where: fm.isExecutableFile(atPath:)) {
            return GHRunner(executable: URL(fileURLWithPath: hit))
        }

        // Last resort: ask a login shell, which knows the user's PATH.
        let shell = URL(fileURLWithPath: "/bin/zsh")
        if let result = try? runSync(shell, ["-lc", "command -v gh"]), result.status == 0 {
            let path = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fm.isExecutableFile(atPath: path) {
                return GHRunner(executable: URL(fileURLWithPath: path))
            }
        }
        return nil
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        let executable = executable
        let environment = Self.environment(for: executable)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try Self.runSync(executable, arguments, environment: environment)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func environment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let preferred = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        let inherited = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        env["PATH"] = (preferred + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    fileprivate static func runSync(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Drain stderr on its own thread so neither pipe can fill up and stall gh.
        let errors = PipeDrain(stderr.fileHandleForReading)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(status: process.terminationStatus, stdout: output, stderr: errors.wait())
    }
}

private final class PipeDrain: @unchecked Sendable {
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
