import Foundation

/// User-tunable values, read from `defaults` (domain `com.rikuws.docknotch`).
///
///     defaults write com.rikuws.docknotch searchQualifier "org:acme"
enum Settings {
    private static var defaults: UserDefaults { .standard }

    /// Extra GitHub search qualifiers appended to every query, e.g. `org:acme` or `repo:me/app`.
    static var searchQualifier: String {
        defaults.string(forKey: "searchQualifier")?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Seconds between GitHub fetches.
    static var refreshInterval: TimeInterval {
        max(20, defaults.double(forKey: "refreshInterval").nonZero ?? 60)
    }

    /// Seconds each card stays on screen.
    static var rotationInterval: TimeInterval {
        max(3, defaults.double(forKey: "rotationInterval").nonZero ?? 7)
    }

    /// Most stat tiles to show beside the rotating card when there's room. 0 shows the card alone.
    static var maxTiles: Int {
        defaults.object(forKey: "maxTiles") as? Int ?? TileKind.allCases.count
    }

    /// Explicit path to the `gh` binary, for installs outside the usual locations.
    static var ghPath: String? {
        defaults.string(forKey: "ghPath")
    }

    static var didPromptForAccessibility: Bool {
        get { defaults.bool(forKey: "didPromptForAccessibility") }
        set { defaults.set(newValue, forKey: "didPromptForAccessibility") }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
