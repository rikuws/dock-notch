import SwiftUI

/// How the free space beside the Dock is shared: the rotating card keeps its preferred
/// width, and as many stat tiles as fit fill the rest. Leftover space widens the tiles,
/// then the card.
struct StripLayout: Equatable {
    static let heroPreferredWidth: CGFloat = 400
    private static let heroMaxWidth: CGFloat = 600
    private static let tileMinWidth: CGFloat = 100
    private static let tileMaxWidth: CGFloat = 136

    let heroWidth: CGFloat
    let tileWidth: CGFloat
    let tiles: [TileKind]
    let spacing: CGFloat

    var totalWidth: CGFloat { heroWidth + CGFloat(tiles.count) * (tileWidth + spacing) }

    /// The gap between boxes, and between the strip and the Dock or screen edge.
    static func spacing(forHeight height: CGFloat) -> CGFloat {
        10 * max(height, 1) / 84
    }

    /// Widths are in points for an 84pt-tall strip (the default Dock) and scale with `height`.
    init(width: CGFloat, height: CGFloat, maxTiles: Int = Settings.maxTiles) {
        let scale = max(height, 1) / 84
        let heroPreferred = Self.heroPreferredWidth * scale
        let tileMin = Self.tileMinWidth * scale
        spacing = Self.spacing(forHeight: height)

        let fitting = max(0, Int((width - heroPreferred) / (tileMin + spacing)))
        let count = min(fitting, max(0, maxTiles), TileKind.allCases.count)
        guard count > 0 else {
            heroWidth = max(0, min(width, Self.heroMaxWidth * scale))
            tileWidth = 0
            tiles = []
            return
        }

        tiles = Array(TileKind.allCases.prefix(count))
        let share = ((width - heroPreferred) / CGFloat(count) - spacing).rounded(.down)
        tileWidth = min(Self.tileMaxWidth * scale, share)
        heroWidth = min(Self.heroMaxWidth * scale, width - CGFloat(count) * (tileWidth + spacing))
    }

    /// The box `x` points from the strip's leading edge lands on; nil in the gaps.
    func box(at x: CGFloat) -> StripBox? {
        if x >= 0, x < heroWidth { return .card }
        for (index, tile) in tiles.enumerated() {
            let range = span(ofTileAt: index)
            if x >= range.lowerBound, x < range.upperBound { return .tile(tile) }
        }
        return nil
    }

    /// Where a box starts and ends, measured from the strip's leading edge.
    func span(of box: StripBox) -> Range<CGFloat>? {
        switch box {
        case .card: 0..<heroWidth
        case .tile(let tile): tiles.firstIndex(of: tile).map(span(ofTileAt:))
        }
    }

    private func span(ofTileAt index: Int) -> Range<CGFloat> {
        let minX = heroWidth + spacing + CGFloat(index) * (tileWidth + spacing)
        return minX..<(minX + tileWidth)
    }
}

/// A box in the strip: the rotating card or one of the tiles.
enum StripBox: Hashable {
    case card
    case tile(TileKind)
}

/// A small always-visible box with one number. Listed in the order they're added as
/// space allows.
enum TileKind: String, CaseIterable {
    case openPRs, reviews, checks, merged, thisWeek

    /// The rotating card this tile makes redundant, so the card can drop out of rotation.
    var replacesCard: CardKind? {
        switch self {
        case .openPRs: .openPRs
        case .reviews: .reviews
        case .checks: .checks
        case .merged: .merged
        // The contributions card also carries the yearly total and chart, so it stays.
        case .thisWeek: nil
        }
    }
}

struct TileModel {
    enum Value {
        case count(Int)
        case ratio(Int, of: Int)
        case none
    }

    let caption: String
    let value: Value
    let status: String
    let tint: Color

    static func make(_ tile: TileKind, snapshot: Snapshot?) -> TileModel {
        guard let snapshot else {
            return TileModel(caption: caption(for: tile), value: .none, status: " ", tint: Palette.tertiary)
        }
        switch tile {
        case .openPRs:
            let prs = snapshot.openPRs
            let (status, tint): (String, Color) =
                if prs.approved > 0 { ("\(prs.approved) approved", Palette.green) }
                else if prs.changesRequested > 0 { ("\(prs.changesRequested) to fix", Palette.amber) }
                else if prs.awaitingReview > 0 { ("\(prs.awaitingReview) in review", Palette.secondary) }
                else if prs.drafts > 0 { ("\(prs.drafts) draft\(prs.drafts == 1 ? "" : "s")", Palette.secondary) }
                else { ("none", Palette.tertiary) }
            return TileModel(caption: caption(for: tile), value: .count(prs.total), status: status, tint: tint)

        case .reviews:
            let queue = snapshot.reviewQueue
            return TileModel(
                caption: caption(for: tile),
                value: .count(queue.count),
                status: queue.count > 0 ? queue.latestAuthor.map { "@\($0)" } ?? "waiting" : "all clear",
                tint: queue.count > 0 ? Palette.green : Palette.secondary
            )

        case .checks:
            guard let checks = snapshot.checks else {
                return TileModel(caption: caption(for: tile), value: .none, status: "no runs", tint: Palette.tertiary)
            }
            let (status, tint): (String, Color) =
                if checks.failing > 0 { ("\(checks.failing) failing", Palette.red) }
                else if checks.pending > 0 { ("\(checks.pending) running", Palette.amber) }
                else { ("passing", Palette.green) }
            return TileModel(
                caption: caption(for: tile),
                value: .ratio(checks.passing, of: checks.total),
                status: status,
                tint: tint
            )

        case .merged:
            let merged = snapshot.merged
            return TileModel(
                caption: caption(for: tile),
                value: .count(merged.count),
                status: "last 7 days",
                tint: merged.count > 0 ? Palette.green : Palette.secondary
            )

        case .thisWeek:
            let c = snapshot.contributions
            let delta = c.thisWeek - c.lastWeek
            return TileModel(
                caption: caption(for: tile),
                value: .count(c.thisWeek),
                status: delta >= 0 ? "+\(delta) vs last" : "\(delta) vs last",
                tint: delta >= 0 ? Palette.green : Palette.secondary
            )
        }
    }

    private static func caption(for tile: TileKind) -> String {
        switch tile {
        case .openPRs: "Open PRs"
        case .reviews: "To review"
        case .checks: "Checks"
        case .merged: "Merged"
        case .thisWeek: "This week"
        }
    }
}
