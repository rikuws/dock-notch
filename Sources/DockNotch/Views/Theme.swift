import SwiftUI

enum Palette {
    static let green = Color(red: 0.25, green: 0.73, blue: 0.31)
    static let mint = Color(red: 0.40, green: 0.92, blue: 0.55)
    static let red = Color(red: 0.97, green: 0.32, blue: 0.29)
    static let amber = Color(red: 0.89, green: 0.66, blue: 0.20)

    static let primary = Color.white.opacity(0.96)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.09)
}

/// Every size in the pill derives from its height, so the notch scales with the Dock.
/// The design reference is a 70pt-tall pill.
struct NotchMetrics {
    let size: CGSize

    var scale: CGFloat { size.height / 70 }
    var radius: CGFloat { 20 * scale }
    var leading: CGFloat { 18 * scale }
    var tileInset: CGFloat { 8 * scale }
    var tile: CGFloat { size.height - tileInset * 2 }
    /// Concentric with the pill's corners.
    var tileRadius: CGFloat { radius - tileInset }
    var chartWidth: CGFloat { size.width * 0.46 }
    var headlineHeight: CGFloat { 31 * scale }

    var caption: Font { .system(size: 11 * scale) }
    var headline: Font { .system(size: 26 * scale, weight: .semibold).monospacedDigit() }
    var quote: Font { .system(size: 16 * scale, weight: .semibold) }
    var footnote: Font { .system(size: 11 * scale) }
    var footnoteLead: Font { .system(size: 11 * scale, weight: .medium) }
    var footnoteIcon: Font { .system(size: 10 * scale, weight: .semibold) }
    var tileSymbol: Font { .system(size: 22 * scale, weight: .semibold) }

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
    static let hover = Animation.spring(duration: 0.35, bounce: 0.3)
    static let chartReveal = Animation.easeOut(duration: 1.1).delay(0.15)
}
