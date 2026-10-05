import SwiftUI

/// A simple hand-drawn-style dog face, drawn as vector strokes so it needs no image asset
/// and stays crisp at any card size. Slightly wobbly curves and round caps keep it playful.
struct DogIllustration: View {
    var ink: Color = Color(red: 0.26, green: 0.18, blue: 0.11)
    var fur: Color = Color(red: 0.93, green: 0.72, blue: 0.36)
    var lineWidth: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            // Floppy ears sit behind the head.
            for side in [CGFloat(-1), 1] {
                var ear = Path()
                let base = 0.5 + side * 0.27
                ear.move(to: point(base, 0.22))
                ear.addCurve(to: point(0.5 + side * 0.47, 0.7),
                             control1: point(0.5 + side * 0.52, 0.16),
                             control2: point(0.5 + side * 0.53, 0.55))
                ear.addCurve(to: point(0.5 + side * 0.3, 0.6),
                             control1: point(0.5 + side * 0.42, 0.78),
                             control2: point(0.5 + side * 0.33, 0.72))
                context.fill(ear, with: .color(fur.opacity(0.85)))
                context.stroke(ear, with: .color(ink), style: stroke)
            }

            // Head.
            var head = Path()
            head.move(to: point(0.5, 0.14))
            head.addCurve(to: point(0.78, 0.5), control1: point(0.7, 0.14), control2: point(0.79, 0.32))
            head.addCurve(to: point(0.5, 0.9), control1: point(0.77, 0.72), control2: point(0.66, 0.9))
            head.addCurve(to: point(0.22, 0.5), control1: point(0.34, 0.9), control2: point(0.23, 0.72))
            head.addCurve(to: point(0.5, 0.14), control1: point(0.21, 0.32), control2: point(0.3, 0.14))
            context.fill(head, with: .color(fur))
            context.stroke(head, with: .color(ink), style: stroke)

            // Muzzle.
            let muzzle = Path(ellipseIn: CGRect(x: 0.33 * w, y: 0.5 * h, width: 0.34 * w, height: 0.3 * h))
            context.fill(muzzle, with: .color(.white.opacity(0.85)))
            context.stroke(muzzle, with: .color(ink), style: stroke)

            // Eyes with a highlight.
            for x in [0.38, 0.62] as [CGFloat] {
                let eye = Path(ellipseIn: CGRect(x: (x - 0.04) * w, y: 0.4 * h, width: 0.08 * w, height: 0.09 * h))
                context.fill(eye, with: .color(ink))
                let shine = Path(ellipseIn: CGRect(x: (x - 0.01) * w, y: 0.415 * h, width: 0.02 * w, height: 0.025 * h))
                context.fill(shine, with: .color(.white))
            }

            // Nose, smile and tongue.
            let nose = Path(ellipseIn: CGRect(x: 0.44 * w, y: 0.53 * h, width: 0.12 * w, height: 0.08 * h))
            context.fill(nose, with: .color(ink))
            var smile = Path()
            smile.move(to: point(0.5, 0.61))
            smile.addLine(to: point(0.5, 0.66))
            smile.addQuadCurve(to: point(0.4, 0.68), control: point(0.46, 0.72))
            smile.move(to: point(0.5, 0.66))
            smile.addQuadCurve(to: point(0.6, 0.68), control: point(0.54, 0.72))
            context.stroke(smile, with: .color(ink), style: stroke)
            var tongue = Path()
            tongue.move(to: point(0.46, 0.7))
            tongue.addQuadCurve(to: point(0.54, 0.7), control: point(0.5, 0.86))
            tongue.closeSubpath()
            context.fill(tongue, with: .color(Color(red: 0.93, green: 0.45, blue: 0.5)))
            context.stroke(tongue, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth * 0.7, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
