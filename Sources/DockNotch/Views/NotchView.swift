import SwiftUI

/// Window padding around the boxes, so their shadows and highlight glow aren't clipped.
let notchShadowPadding: CGFloat = 20

/// The rotating card followed by as many stat tiles as the window's width allows.
/// Layout is derived from the live size, so the strip follows the Dock as it resizes.
struct NotchView: View {
    let store: NotchStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(
                width: max(0, geometry.size.width - notchShadowPadding * 2),
                height: max(0, geometry.size.height - notchShadowPadding * 2)
            )
            let layout = StripLayout(width: size.width, height: size.height)

            HStack(spacing: layout.spacing) {
                HeroBox(store: store, size: CGSize(width: layout.heroWidth, height: size.height))
                ForEach(layout.tiles, id: \.self) { tile in
                    StatBox(tile: tile, store: store, size: CGSize(width: layout.tileWidth, height: size.height))
                        .transition(reduceMotion
                            ? .opacity
                            : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
                }
            }
            .animation(Motion.layout, value: layout.tiles)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .padding(notchShadowPadding)
            .onChange(of: layout.tiles, initial: true) { _, tiles in
                store.setVisibleTiles(tiles)
            }
        }
    }
}

private struct HeroBox: View {
    let store: NotchStore
    let size: CGSize

    var body: some View {
        let metrics = NotchMetrics(size: size)
        CardView(card: .make(for: store), metrics: metrics, avatars: store.avatars)
            .modifier(BoxChrome(size: size, radius: metrics.radius, highlight: store.highlight))
            .onTapGesture { store.openCurrent() }
    }
}

private struct StatBox: View {
    let tile: TileKind
    let store: NotchStore
    let size: CGSize

    var body: some View {
        let metrics = NotchMetrics(size: size)
        let model = TileModel.make(tile, snapshot: store.snapshot)

        VStack(alignment: .leading, spacing: 0) {
            Text(model.caption)
                .font(metrics.caption)
                .foregroundStyle(Palette.secondary)
            value(model.value, metrics: metrics)
                .frame(height: metrics.headlineHeight, alignment: .leading)
            Text(model.status)
                .font(metrics.footnoteLead)
                .foregroundStyle(model.tint)
        }
        .lineLimit(1)
        .padding(.horizontal, metrics.statPadding)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .modifier(BoxChrome(size: size, radius: metrics.radius, highlight: store.tileHighlights[tile] ?? 0))
        .onTapGesture { store.open(tile) }
    }

    @ViewBuilder
    private func value(_ value: TileModel.Value, metrics: NotchMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch value {
            case .count(let count):
                CountText(value: count)
            case .ratio(let part, let whole):
                CountText(value: part)
                Text("/\(whole)").foregroundStyle(Palette.tertiary)
            case .none:
                Text("–").foregroundStyle(Palette.tertiary)
            }
        }
        .font(metrics.headline)
        .kerning(-0.4 * metrics.scale)
        .foregroundStyle(Palette.primary)
    }
}

/// The black, hairline-edged box every part of the strip sits in, with a green glow
/// that plays each time `highlight` changes.
private struct BoxChrome: ViewModifier {
    let size: CGSize
    let radius: CGFloat
    let highlight: Int

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(width: size.width, height: size.height)
            .background(shape.fill(.black))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .keyframeAnimator(initialValue: 0.0, trigger: highlight) { content, glow in
                content
                    .overlay(shape.strokeBorder(Palette.green.opacity(0.85 * glow), lineWidth: 1.5))
                    .shadow(color: Palette.green.opacity(0.5 * glow), radius: 12 * glow)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.25)
                CubicKeyframe(1, duration: 0.5)
                CubicKeyframe(0, duration: 1.8)
            }
            // Layered shadow: a tight contact shadow under a soft ambient one.
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            .contentShape(shape)
    }
}

private struct CountText: View {
    let value: Int

    var body: some View {
        Text(value, format: .number)
            .contentTransition(.numericText(value: Double(value)))
            .animation(Motion.counter, value: value)
    }
}

private struct CardView: View {
    let card: CardModel
    let metrics: NotchMetrics
    let avatars: AvatarCache

    var body: some View {
        ZStack(alignment: .leading) {
            Slot(id: card.id, order: 3, alignment: .trailing) {
                accessory
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 0) {
                Slot(id: card.id, order: 0) {
                    Text(card.caption)
                        .font(metrics.caption)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Slot(id: card.id, order: 1) {
                    headline
                }
                .frame(height: metrics.headlineHeight, alignment: .leading)
                Slot(id: card.id, order: 2) {
                    footnote
                }
            }
            .padding(.leading, metrics.leading)
            .padding(.trailing, metrics.reservedTrailing(for: card.accessory))
            // Optical nudge: line-height leaves extra air above the caption.
            .offset(y: -0.5 * metrics.scale)
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch card.headline {
        case .count(let value, let suffix):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                CountText(value: value)
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(Palette.tertiary)
                }
            }
            .font(metrics.headline)
            .kerning(-0.4 * metrics.scale)
            .foregroundStyle(Palette.primary)
            .lineLimit(1)
        case .quote(let text):
            Text("“\(text)”")
                .font(metrics.quote)
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
        case .text(let text):
            Text(text)
                .font(metrics.headline)
                .kerning(-0.4 * metrics.scale)
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
        }
    }

    private var footnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let icon = card.footnote.icon {
                Image(systemName: icon)
                    .font(metrics.footnoteIcon)
                    .foregroundStyle(card.footnote.tint)
                    .padding(.trailing, 4 * metrics.scale)
            }
            Text(card.footnote.lead)
                .font(metrics.footnoteLead)
                .foregroundStyle(card.footnote.tint)
                .fixedSize()
            Text(card.footnote.rest)
                .font(metrics.footnote)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch card.accessory {
        case .chart(let values):
            ContributionChart(values: values)
                .frame(width: metrics.chartWidth, height: metrics.size.height)
        case .symbol(let name):
            Tile(metrics: metrics) {
                Image(systemName: name)
                    .font(metrics.tileSymbol)
                    .foregroundStyle(Palette.primary)
            }
            .padding(.trailing, metrics.tileInset)
        case .avatar(let url, let fallback):
            Tile(metrics: metrics) {
                if let url, let image = avatars.images[url] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: fallback)
                        .font(metrics.tileSymbol)
                        .foregroundStyle(Palette.primary)
                }
            }
            .padding(.trailing, metrics.tileInset)
        }
    }
}

/// One row of a card. When the card changes, the old row lifts out while the new one
/// rises in, overlapping in place. Rows are staggered by `order` so the swap cascades.
private struct Slot<Content: View>: View {
    let id: String
    let order: Int
    var alignment: Alignment = .leading
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: alignment) {
            content
                .id(id)
                .transition(transition)
        }
    }

    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeInOut(duration: 0.25))
        }
        let delay = Double(order) * Motion.rowStagger
        return .asymmetric(
            insertion: .modifier(
                active: Lift(y: 14, blur: 5, opacity: 0),
                identity: Lift(y: 0, blur: 0, opacity: 1)
            )
            .animation(.spring(duration: 0.55, bounce: 0.2).delay(0.08 + delay)),
            removal: .modifier(
                active: Lift(y: -12, blur: 5, opacity: 0),
                identity: Lift(y: 0, blur: 0, opacity: 1)
            )
            .animation(.spring(duration: 0.35, bounce: 0).delay(delay * 0.5))
        )
    }
}

private struct Lift: ViewModifier {
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .offset(y: y)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

struct Tile<Content: View>: View {
    let metrics: NotchMetrics
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.tileRadius, style: .continuous)
        content
            .frame(width: metrics.tile, height: metrics.tile)
            .background(shape.fill(LinearGradient(
                colors: [Color(white: 0.17), Color(white: 0.07)],
                startPoint: .top, endPoint: .bottom
            )))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
