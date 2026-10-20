import Foundation

/// Where this copy of the app came from. `scripts/bundle.sh` stamps it into Info.plist.
struct BuildInfo: Sendable {
    enum Channel: String, Sendable {
        /// A signed release from GitHub. It updates itself with Sparkle.
        case release
        /// Built from a checkout, perhaps with your own changes. It updates by moving those
        /// changes onto the newer release's source and rebuilding, so they carry over.
        case source
    }

    let channel: Channel
    let version: String
    /// The checkout a source build came from. Nil when there isn't one to update, as with `swift run`.
    let sourceDirectory: URL?
    /// The commit a source build was made from, with "-dirty" for uncommitted changes.
    let revision: String?
    /// Commits on top of the release a source build is based on: your changes.
    let changes: Int
    /// The repository whose releases this build follows, as owner/name.
    let upstream: String

    static let current = BuildInfo(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        channel = (info["DNChannel"] as? String).flatMap(Channel.init) ?? .source
        version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        sourceDirectory = (info["DNSourceDirectory"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        revision = info["DNSourceRevision"] as? String
        changes = info["DNSourceChanges"] as? Int ?? 0
        upstream = info["DNUpstreamRepository"] as? String ?? "rikuws/dock-notch"
    }

    /// For the menu: "Dock Notch 0.2.0", or "Dock Notch 0.2.0 + 3 changes" for a customized build.
    var title: String {
        switch channel {
        case .release: "Dock Notch \(version)"
        case .source where changes > 0: "Dock Notch \(version) + \(changes) change\(changes == 1 ? "" : "s")"
        case .source: "Dock Notch \(version) (from source)"
        }
    }

    /// Whether `tag`, like "v0.3.0", is a newer release than this build is based on.
    func isOlder(than tag: String) -> Bool {
        let other = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.compare(other, options: .numeric) == .orderedAscending
    }
}
