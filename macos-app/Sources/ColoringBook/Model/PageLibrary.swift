import AppKit
import CoreGraphics
import Foundation

/// Built-in procedural line-art pages. Rendered to transparent PNG via
/// Core Graphics so the app ships without binary image assets.
enum PageLibrary {
    static let blank = CurrentPage(
        pageId: "blank",
        displayName: "Blank Paper",
        imageData: nil
    )

    static func builtIn() -> [CurrentPage] {
        [
            blank,
            page(id: "mandala",  name: "Mandala",  draw: drawMandala),
            page(id: "flower",   name: "Tulip",    draw: drawFlower),
            page(id: "cottage",  name: "Cottage",  draw: drawCottage),
        ]
    }

    // MARK: Rendering helpers

    private static func page(
        id: String,
        name: String,
        size: Int = 1024,
        draw: (CGContext, Double) -> Void
    ) -> CurrentPage {
        let pngData = renderPNG(size: size) { ctx in
            draw(ctx, Double(size))
        }
        return CurrentPage(pageId: id, displayName: name, imageData: pngData)
    }

    private static func renderPNG(
        size: Int,
        _ body: (CGContext) -> Void
    ) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: space, bitmapInfo: info
        ) else { return Data() }

        // Transparent bg, black ink, rounded caps.
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setStrokeColor(CGColor(red: 0.12, green: 0.10, blue: 0.12, alpha: 1))
        ctx.setLineWidth(Double(size) * 0.004)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Convert to a "y-down" coordinate system for easier composing —
        // flip vertically around the middle, so paths authored with (0,0)
        // at top-left produce upright output.
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)

        body(ctx)

        guard let image = ctx.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: — Mandala

    private static func drawMandala(_ ctx: CGContext, _ size: Double) {
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.setLineWidth(size * 0.0045)

        // Concentric circles
        for r in stride(from: size * 0.07, through: size * 0.44, by: size * 0.07) {
            ctx.addArc(center: c, radius: r, startAngle: 0,
                       endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }

        // 12-fold radial petals
        let petals = 12
        for i in 0 ..< petals {
            let a = Double(i) * (.pi * 2) / Double(petals)
            let ca = cos(a), sa = sin(a)
            let perp = (x: -sa, y: ca)

            // Inner spoke
            ctx.move(to: CGPoint(x: c.x + ca * size * 0.14, y: c.y + sa * size * 0.14))
            ctx.addLine(to: CGPoint(x: c.x + ca * size * 0.44, y: c.y + sa * size * 0.44))
            ctx.strokePath()

            // Teardrop petal between r=0.18 and r=0.32
            let baseR = size * 0.18
            let tipR  = size * 0.30
            let base  = CGPoint(x: c.x + ca * baseR, y: c.y + sa * baseR)
            let tip   = CGPoint(x: c.x + ca * tipR,  y: c.y + sa * tipR)
            let w = size * 0.028
            let s1 = CGPoint(x: base.x + perp.x * w, y: base.y + perp.y * w)
            let s2 = CGPoint(x: base.x - perp.x * w, y: base.y - perp.y * w)
            ctx.move(to: s1)
            ctx.addQuadCurve(to: tip,
                control: CGPoint(x: (s1.x + tip.x) / 2 + perp.x * size * 0.012,
                                 y: (s1.y + tip.y) / 2 + perp.y * size * 0.012))
            ctx.addQuadCurve(to: s2,
                control: CGPoint(x: (s2.x + tip.x) / 2 - perp.x * size * 0.012,
                                 y: (s2.y + tip.y) / 2 - perp.y * size * 0.012))
            ctx.strokePath()

            // Outer decorative dot
            let outer = CGPoint(x: c.x + ca * size * 0.47, y: c.y + sa * size * 0.47)
            ctx.addArc(center: outer, radius: size * 0.018,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }

        // Fill center with a small flower
        ctx.setLineWidth(size * 0.003)
        for i in 0 ..< 6 {
            let a = Double(i) * (.pi / 3)
            let tip = CGPoint(x: c.x + cos(a) * size * 0.06, y: c.y + sin(a) * size * 0.06)
            ctx.addArc(center: tip, radius: size * 0.022,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }
        ctx.addArc(center: c, radius: size * 0.018,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
    }

    // MARK: — Tulip in a garden

    private static func drawFlower(_ ctx: CGContext, _ size: Double) {
        ctx.setLineWidth(size * 0.0055)

        let cx = size * 0.5
        let baseY = size * 0.82

        // Ground line with gentle waves
        ctx.move(to: CGPoint(x: 0, y: baseY))
        var x = 0.0
        while x < size {
            ctx.addQuadCurve(
                to: CGPoint(x: x + size * 0.12, y: baseY),
                control: CGPoint(x: x + size * 0.06, y: baseY - size * 0.012)
            )
            x += size * 0.12
        }
        ctx.strokePath()

        // Stem
        ctx.move(to: CGPoint(x: cx, y: baseY))
        ctx.addCurve(
            to: CGPoint(x: cx, y: size * 0.40),
            control1: CGPoint(x: cx - size * 0.03, y: size * 0.68),
            control2: CGPoint(x: cx + size * 0.03, y: size * 0.52)
        )
        ctx.strokePath()

        // Leaf (left side of stem)
        ctx.move(to: CGPoint(x: cx - size * 0.002, y: size * 0.60))
        ctx.addQuadCurve(
            to: CGPoint(x: cx - size * 0.18, y: size * 0.54),
            control: CGPoint(x: cx - size * 0.14, y: size * 0.48)
        )
        ctx.addQuadCurve(
            to: CGPoint(x: cx - size * 0.002, y: size * 0.62),
            control: CGPoint(x: cx - size * 0.10, y: size * 0.62)
        )
        ctx.strokePath()

        // Tulip blossom — three petals
        // Center petal
        ctx.move(to: CGPoint(x: cx, y: size * 0.40))
        ctx.addCurve(
            to: CGPoint(x: cx, y: size * 0.20),
            control1: CGPoint(x: cx - size * 0.06, y: size * 0.35),
            control2: CGPoint(x: cx - size * 0.04, y: size * 0.22)
        )
        ctx.addCurve(
            to: CGPoint(x: cx, y: size * 0.40),
            control1: CGPoint(x: cx + size * 0.04, y: size * 0.22),
            control2: CGPoint(x: cx + size * 0.06, y: size * 0.35)
        )
        ctx.strokePath()

        // Left petal
        ctx.move(to: CGPoint(x: cx - size * 0.035, y: size * 0.40))
        ctx.addCurve(
            to: CGPoint(x: cx - size * 0.10, y: size * 0.25),
            control1: CGPoint(x: cx - size * 0.10, y: size * 0.36),
            control2: CGPoint(x: cx - size * 0.12, y: size * 0.30)
        )
        ctx.addCurve(
            to: CGPoint(x: cx - size * 0.012, y: size * 0.27),
            control1: CGPoint(x: cx - size * 0.08, y: size * 0.22),
            control2: CGPoint(x: cx - size * 0.04, y: size * 0.24)
        )
        ctx.strokePath()

        // Right petal
        ctx.move(to: CGPoint(x: cx + size * 0.035, y: size * 0.40))
        ctx.addCurve(
            to: CGPoint(x: cx + size * 0.10, y: size * 0.25),
            control1: CGPoint(x: cx + size * 0.10, y: size * 0.36),
            control2: CGPoint(x: cx + size * 0.12, y: size * 0.30)
        )
        ctx.addCurve(
            to: CGPoint(x: cx + size * 0.012, y: size * 0.27),
            control1: CGPoint(x: cx + size * 0.08, y: size * 0.22),
            control2: CGPoint(x: cx + size * 0.04, y: size * 0.24)
        )
        ctx.strokePath()

        // Tiny grass tufts
        ctx.setLineWidth(size * 0.0035)
        let positions = [0.12, 0.24, 0.70, 0.82, 0.92]
        for p in positions {
            let gx = size * p
            for i in -1 ... 1 {
                let dx = Double(i) * size * 0.006
                ctx.move(to: CGPoint(x: gx + dx, y: baseY))
                ctx.addQuadCurve(
                    to: CGPoint(x: gx + dx * 2, y: baseY - size * 0.025),
                    control: CGPoint(x: gx + dx * 1.5, y: baseY - size * 0.012)
                )
                ctx.strokePath()
            }
        }

        // A sun in the top-right corner
        ctx.setLineWidth(size * 0.0045)
        let sun = CGPoint(x: size * 0.82, y: size * 0.14)
        ctx.addArc(center: sun, radius: size * 0.05,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        for i in 0 ..< 8 {
            let a = Double(i) * (.pi / 4)
            let p1 = CGPoint(x: sun.x + cos(a) * size * 0.065, y: sun.y + sin(a) * size * 0.065)
            let p2 = CGPoint(x: sun.x + cos(a) * size * 0.095, y: sun.y + sin(a) * size * 0.095)
            ctx.move(to: p1)
            ctx.addLine(to: p2)
            ctx.strokePath()
        }
    }

    // MARK: — Little cottage

    private static func drawCottage(_ ctx: CGContext, _ size: Double) {
        ctx.setLineWidth(size * 0.0055)

        let baseY = size * 0.78

        // Ground
        ctx.move(to: CGPoint(x: 0, y: baseY))
        ctx.addLine(to: CGPoint(x: size, y: baseY))
        ctx.strokePath()

        // House body
        let hx: Double = size * 0.30
        let hy: Double = size * 0.44
        let hw: Double = size * 0.40
        let hh: Double = size * 0.34

        ctx.stroke(CGRect(x: hx, y: hy, width: hw, height: hh))

        // Roof (triangle)
        ctx.move(to: CGPoint(x: hx - size * 0.02, y: hy))
        ctx.addLine(to: CGPoint(x: hx + hw / 2, y: hy - size * 0.18))
        ctx.addLine(to: CGPoint(x: hx + hw + size * 0.02, y: hy))
        ctx.strokePath()

        // Chimney
        let chx = hx + hw * 0.75
        ctx.stroke(CGRect(
            x: chx, y: hy - size * 0.12,
            width: size * 0.04, height: size * 0.08
        ))

        // Door
        let dx = hx + hw * 0.42
        let dw = hw * 0.16
        let dy = hy + hh - size * 0.17
        ctx.stroke(CGRect(x: dx, y: dy, width: dw, height: size * 0.17))
        // Doorknob
        ctx.addArc(center: CGPoint(x: dx + dw * 0.82, y: dy + size * 0.085),
                   radius: size * 0.005, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Window (with cross)
        let wsize = size * 0.10
        let wx = hx + size * 0.04
        let wy = hy + size * 0.05
        ctx.stroke(CGRect(x: wx, y: wy, width: wsize, height: wsize))
        ctx.move(to: CGPoint(x: wx + wsize / 2, y: wy))
        ctx.addLine(to: CGPoint(x: wx + wsize / 2, y: wy + wsize))
        ctx.move(to: CGPoint(x: wx, y: wy + wsize / 2))
        ctx.addLine(to: CGPoint(x: wx + wsize, y: wy + wsize / 2))
        ctx.strokePath()

        // Tree on the right
        let trunkX = size * 0.80
        ctx.stroke(CGRect(
            x: trunkX - size * 0.018, y: baseY - size * 0.16,
            width: size * 0.036, height: size * 0.16
        ))
        ctx.addArc(center: CGPoint(x: trunkX, y: baseY - size * 0.24),
                   radius: size * 0.10, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Bushes
        ctx.setLineWidth(size * 0.0045)
        for bx in [0.08, 0.14, 0.21] as [Double] {
            let cx = size * bx
            let cy = baseY - size * 0.025
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: size * 0.03,
                       startAngle: .pi, endAngle: 0, clockwise: true)
            ctx.strokePath()
        }

        // Clouds
        ctx.setLineWidth(size * 0.0045)
        for (cx, cy, r) in [
            (0.18, 0.18, 0.05),
            (0.25, 0.16, 0.04),
            (0.72, 0.10, 0.045),
            (0.79, 0.12, 0.038),
        ] as [(Double, Double, Double)] {
            ctx.addArc(
                center: CGPoint(x: size * cx, y: size * cy),
                radius: size * r,
                startAngle: .pi, endAngle: 0, clockwise: true
            )
            ctx.strokePath()
        }

        // Path from door to the edge
        ctx.setLineWidth(size * 0.0035)
        ctx.move(to: CGPoint(x: dx + dw / 2, y: dy + size * 0.17))
        ctx.addCurve(
            to: CGPoint(x: size * 0.42, y: baseY),
            control1: CGPoint(x: dx + dw / 2, y: dy + size * 0.22),
            control2: CGPoint(x: size * 0.45, y: baseY - size * 0.02)
        )
        ctx.strokePath()
        ctx.move(to: CGPoint(x: dx + dw / 2 + size * 0.03, y: dy + size * 0.17))
        ctx.addCurve(
            to: CGPoint(x: size * 0.50, y: baseY),
            control1: CGPoint(x: dx + dw / 2 + size * 0.03, y: dy + size * 0.22),
            control2: CGPoint(x: size * 0.52, y: baseY - size * 0.02)
        )
        ctx.strokePath()
    }
}
