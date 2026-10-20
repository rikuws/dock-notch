import SwiftUI

enum Palette {
    static let green = Color(red: 0.25, green: 0.73, blue: 0.31)
    static let mint = Color(red: 0.40, green: 0.92, blue: 0.55)
    static let red = Color(red: 0.97, green: 0.32, blue: 0.29)
    static let amber = Color(red: 0.89, green: 0.66, blue: 0.20)
    static let link = Color(red: 0.45, green: 0.68, blue: 1.0)

    static let primary = Color.white.opacity(0.96)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.09)
}

/// Every size in a box derives from its height, which matches the Dock's. The design
/// reference is the default Dock: 84pt tall, with 64pt icons inset 10pt.
struct NotchMetrics {
    let size: CGSize

    var scale: CGFloat { size.height / 84 }
    var radius: CGFloat { 24 * scale }
    var leading: CGFloat { 20 * scale }
    /// The Dock's own inset, so avatars and symbols sit like Dock icons.
    var tileInset: CGFloat { 10 * scale }
    var tile: CGFloat { size.height - tileInset * 2 }
    /// Concentric with the box's corners; about an app icon's radius at 64pt.
    var tileRadius: CGFloat { radius - tileInset }
    var chartWidth: CGFloat { size.width * 0.46 }
    /// Caption, headline and footnote stack to about 64pt, leaving the Dock's 10pt above and below.
    var headlineHeight: CGFloat { 33 * scale }
    var statPadding: CGFloat { 13 * scale }

    var caption: Font { .system(size: 13 * scale) }
    var headline: Font { .system(size: 29 * scale, weight: .semibold).monospacedDigit() }
    var quote: Font { .system(size: 18 * scale, weight: .semibold) }
    var footnote: Font { .system(size: 13 * scale) }
    var footnoteLead: Font { .system(size: 13 * scale, weight: .medium) }
    var footnoteIcon: Font { .system(size: 12 * scale, weight: .semibold) }
    var tileSymbol: Font { .system(size: 26 * scale, weight: .semibold) }

    func reservedTrailing(for accessory: CardModel.Accessory) -> CGFloat {
        switch accessory {
        // Text may run into the chart's faded left edge.
        case .chart: size.width * 0.36
        case .symbol, .avatar: tile + tileInset * 2
        }
    }
}

enum Motion {
    static let cardSwap = Animation.spring(duration: 0.5, bounce: 0.15)
    static let rowStagger: Double = 0.045
    static let counter = Animation.spring(duration: 0.6, bounce: 0.1)
    static let layout = Animation.spring(duration: 0.45, bounce: 0.12)
    static let chartReveal = Animation.easeOut(duration: 1.1).delay(0.15)
}
