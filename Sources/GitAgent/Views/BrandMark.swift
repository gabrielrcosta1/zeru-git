import SwiftUI

/// The Git Agent mark, drawn as vectors so it stays crisp at any size and in
/// both appearances. Same geometry as the app icon.
struct BrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                return CGPoint(x: x * side, y: y * side)
            }

            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Theme.brandLight, Theme.brand]),
                startPoint: point(0.1, 0.05),
                endPoint: point(0.9, 0.95))

            let nodes = [point(0.20, 0.20), point(0.37, 0.55), point(0.70, 0.80)]

            var links = Path()
            links.move(to: nodes[0])
            links.addLine(to: nodes[1])
            links.move(to: nodes[1])
            links.addLine(to: nodes[2])
            context.stroke(links, with: shading,
                           style: StrokeStyle(lineWidth: side * 0.115, lineCap: .round))

            for node in nodes {
                let radius = side * 0.113
                let ring = Path(ellipseIn: CGRect(x: node.x - radius,
                                                  y: node.y - radius,
                                                  width: radius * 2,
                                                  height: radius * 2))
                context.stroke(ring, with: shading, style: StrokeStyle(lineWidth: side * 0.086))
            }

            // Four pointed sparkle with concave arms, like the icon.
            let centre = point(0.76, 0.31)
            let reach = side * 0.20
            let tips = (0..<4).map { index -> CGPoint in
                let angle = CGFloat(index) * .pi / 2 - .pi / 2
                return CGPoint(x: centre.x + cos(angle) * reach,
                               y: centre.y + sin(angle) * reach)
            }
            var star = Path()
            star.move(to: tips[0])
            for index in 0..<4 {
                star.addQuadCurve(to: tips[(index + 1) % 4], control: centre)
            }
            star.closeSubpath()
            context.fill(star, with: shading)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Git Agent")
    }
}
