import SwiftUI

/// Weekly contributions as an area chart that bleeds off the pill's right and bottom edges.
struct ContributionChart: View {
    let values: [Int]

    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchIsStatic) private var isStatic

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = Self.points(for: values, in: size)

            ZStack {
                Self.area(through: points, in: size)
                    .fill(LinearGradient(
                        colors: [Palette.green.opacity(0.95), Palette.green.opacity(0.35), Palette.green.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Self.line(through: points)
                    .stroke(Palette.mint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            // Draw in from the left...
            .mask(alignment: .leading) {
                Rectangle().frame(width: size.width * (isStatic ? 1 : reveal))
            }
            // ...and fade into the pill on the left edge.
            .mask(LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                startPoint: .leading, endPoint: .trailing
            ))
        }
        .onAppear {
            guard !reduceMotion else {
                reveal = 1
                return
            }
            reveal = 0
            withAnimation(Motion.chartReveal) { reveal = 1 }
        }
    }

    private static func points(for values: [Int], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else {
            return [CGPoint(x: 0, y: size.height * 0.9), CGPoint(x: size.width, y: size.height * 0.9)]
        }
        let peak = CGFloat(max(values.max() ?? 0, 1))
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * step,
                y: size.height * 0.92 - CGFloat(value) / peak * size.height * 0.78
            )
        }
    }

    private static func line(through points: [CGPoint]) -> Path {
        Path { path in path.addLines(points) }
    }

    private static func area(through points: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            path.addLines(points)
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}
