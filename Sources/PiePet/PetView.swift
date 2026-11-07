import SwiftUI

/// Vector redraw of the "Pi on a pie" mascot. Designed in a 150 x 190 unit box.
struct PetView: View {
    @ObservedObject var state: PetState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s = min(size.width / 150, size.height / 190)
                ctx.translateBy(x: (size.width - 150 * s) / 2, y: (size.height - 190 * s) / 2)
                ctx.scaleBy(x: s, y: s)
                PetDrawing.draw(in: &ctx, t: t, mood: state.mood)
            }
        }
    }
}

enum PetDrawing {
    static func c(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }

    // Palette sampled from the original drawing
    static let ink = c(0x6B4A12)          // warm brown outline
    static let greenTop = c(0x9CC35E), greenBot = c(0x7DA444)
    static let blueTop = c(0xBFE3EA), blueBot = c(0x9ACBD7)
    static let mint = c(0x93E3B8), mintLight = c(0xC4F2D8)
    static let purple = c(0x6E4C6A), salmon = c(0xF29470), orange = c(0xEF7C3C)
    static let crustTop = c(0xFADB6B), crustBot = c(0xE4AA33), crustLine = c(0xC98E22)
    static let fillTop = c(0xEE8A3A), fillBot = c(0xD9622A)
    static let tinTop = c(0xD3DDE8), tinBot = c(0x9DAEC2), tinFlute = c(0x8496AD)
    static let neck = c(0x4E3810)
    static let blush = c(0xF7A1A1)
    static let gold = c(0xF4C542)

    static func draw(in ctx: inout GraphicsContext, t: Double, mood: Mood) {
        let line = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

        let speed: Double = mood == .excited ? 7 : (mood == .sleeping ? 1.2 : 2.2)
        let amp: Double = mood == .excited ? 4.5 : (mood == .sleeping ? 1.0 : 2.2)
        let bob = CGFloat(sin(t * speed) * amp)
        let squish = mood == .excited ? CGFloat(1 + sin(t * speed * 2) * 0.03) : 1

        // ground shadow
        ctx.fill(Path(ellipseIn: CGRect(x: 18, y: 179, width: 114, height: 9)), with: .color(.black.opacity(0.13)))

        drawPie(in: &ctx, line: line)

        // ---------- body (bobs) ----------
        var body = ctx
        body.translateBy(x: 75, y: 112 + bob)
        body.scaleBy(x: 2 - squish, y: squish)
        body.translateBy(x: -75, y: -112)

        // legs: thin pins down into the pie
        for x in [60.0, 68.0, 76.0, 84.0, 92.0] {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 116))
            p.addLine(to: CGPoint(x: x, y: 137 - bob))
            body.stroke(p, with: .color(ink), style: thin)
        }

        // arms
        let wave: Double
        switch mood {
        case .talking: wave = sin(t * 6) * 9
        case .excited: wave = sin(t * 12) * 14
        case .thinking: wave = 6
        case .sleeping: wave = -10
        case .idle: wave = sin(t * 1.5) * 3.5
        }
        drawArm(in: &body, from: CGPoint(x: 54, y: 112), side: -1, wave: wave, line: thin)
        drawArm(in: &body, from: CGPoint(x: 100, y: 112), side: 1, wave: mood == .thinking ? -4 : -wave, line: thin)

        // neck bar
        let neckRect = CGRect(x: 52, y: 106, width: 50, height: 11)
        body.fill(Path(roundedRect: neckRect, cornerRadius: 1.5), with: .color(neck))
        body.fill(Path(CGRect(x: 53, y: 107, width: 48, height: 2)), with: .color(.white.opacity(0.12)))

        // colour blocks on the left side (behind the head)
        let blocks: [(CGFloat, CGFloat, Color)] = [(42, 24, purple), (66, 22, salmon), (88, 16, orange)]
        for (y, h, col) in blocks {
            let r = CGRect(x: 29, y: y, width: 17, height: h)
            body.fill(Path(r), with: .linearGradient(Gradient(colors: [col.opacity(0.95), col]),
                                                      startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            body.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1.5)), with: .color(.white.opacity(0.18)))
            body.stroke(Path(r), with: .color(ink.opacity(0.35)), lineWidth: 0.7)
        }

        // head
        let head = CGRect(x: 42, y: 26, width: 70, height: 84)
        let headPath = Path(roundedRect: head, cornerRadius: 16, style: .continuous)
        var h = body
        h.clip(to: headPath)
        h.fill(Path(CGRect(x: 42, y: 26, width: 35, height: 84)),
               with: .linearGradient(Gradient(colors: [greenTop, greenBot]), startPoint: CGPoint(x: 0, y: 26), endPoint: CGPoint(x: 0, y: 110)))
        h.fill(Path(CGRect(x: 77, y: 26, width: 35, height: 84)),
               with: .linearGradient(Gradient(colors: [blueTop, blueBot]), startPoint: CGPoint(x: 0, y: 26), endPoint: CGPoint(x: 0, y: 110)))
        // glossy inner rim along the bottom-right, like the original's light edge
        var rim = Path()
        rim.move(to: CGPoint(x: 108.5, y: 40))
        rim.addLine(to: CGPoint(x: 108.5, y: 96))
        rim.addQuadCurve(to: CGPoint(x: 96, y: 106.5), control: CGPoint(x: 108.5, y: 106.5))
        rim.addLine(to: CGPoint(x: 79, y: 106.5))
        h.stroke(rim, with: .color(mintLight.opacity(0.85)), lineWidth: 2.4)
        // soft top shine
        h.fill(Path(roundedRect: CGRect(x: 47, y: 30, width: 26, height: 5), cornerRadius: 2.5), with: .color(.white.opacity(0.18)))
        body.stroke(headPath, with: .color(ink), style: line)
        // split line, poking out of the top like a little antenna
        var split = Path()
        split.move(to: CGPoint(x: 77, y: 18))
        split.addLine(to: CGPoint(x: 77, y: 110))
        body.stroke(split, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // mint chip (slightly tilted, like the drawing)
        var chip = Path()
        chip.move(to: CGPoint(x: 92, y: 36.5))
        chip.addLine(to: CGPoint(x: 105, y: 35.5))
        chip.addLine(to: CGPoint(x: 105.5, y: 48))
        chip.addLine(to: CGPoint(x: 92.5, y: 49))
        chip.closeSubpath()
        body.fill(chip, with: .linearGradient(Gradient(colors: [mintLight, mint]), startPoint: CGPoint(x: 92, y: 36), endPoint: CGPoint(x: 105, y: 49)))
        body.stroke(chip, with: .color(ink.opacity(0.45)), lineWidth: 0.8)

        drawFace(in: &body, t: t, mood: mood)

        if mood != .sleeping {
            let spin = mood == .thinking ? t * 3 : 0
            let pulse = 0.75 + 0.25 * sin(t * 3)
            drawSparkle(in: &body, at: CGPoint(x: 31, y: 112), size: 6.5 * pulse, angle: spin)
            drawSparkle(in: &body, at: CGPoint(x: 37, y: 124), size: 3 * pulse, angle: spin)
        }

        // mood extras
        if mood == .sleeping {
            for i in 0..<3 {
                let phase = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let text = Text("z").font(.system(size: 8 + phase * 8, weight: .bold, design: .rounded))
                    .foregroundColor(ink.opacity(1 - phase))
                ctx.draw(text, at: CGPoint(x: 114 + phase * 18 + Double(i) * 2, y: 26 - phase * 24))
            }
        }
        if mood == .thinking {
            for i in 0..<3 {
                let on = Int(t * 3) % 4 > i
                ctx.fill(Path(ellipseIn: CGRect(x: 114 + Double(i) * 8, y: 16, width: 5, height: 5)), with: .color(ink.opacity(on ? 0.9 : 0.25)))
            }
        }
    }

    // MARK: Pie

    static func drawPie(in ctx: inout GraphicsContext, line: StrokeStyle) {
        // tin: fluted sides with a metallic gradient
        var tin = Path()
        tin.move(to: CGPoint(x: 15, y: 150))
        tin.addLine(to: CGPoint(x: 135, y: 150))
        tin.addLine(to: CGPoint(x: 123, y: 179))
        tin.addQuadCurve(to: CGPoint(x: 27, y: 179), control: CGPoint(x: 75, y: 186))
        tin.closeSubpath()
        ctx.fill(tin, with: .linearGradient(Gradient(colors: [tinTop, tinBot]), startPoint: CGPoint(x: 0, y: 150), endPoint: CGPoint(x: 0, y: 184)))
        var tc = ctx
        tc.clip(to: tin)
        let flutes = 11
        for i in 0...flutes {
            let f = Double(i) / Double(flutes)
            let xt = 15 + f * 120, xb = 27 + f * 96
            var band = Path()
            band.move(to: CGPoint(x: xt - 3, y: 150))
            band.addLine(to: CGPoint(x: xt + 3, y: 150))
            band.addLine(to: CGPoint(x: xb + 2.4, y: 186))
            band.addLine(to: CGPoint(x: xb - 2.4, y: 186))
            band.closeSubpath()
            tc.fill(band, with: .color(tinFlute.opacity(0.55)))
            var hi = Path()
            hi.move(to: CGPoint(x: xt + 5, y: 151))
            hi.addLine(to: CGPoint(x: xb + 3.6, y: 186))
            tc.stroke(hi, with: .color(.white.opacity(0.35)), lineWidth: 0.9)
        }
        ctx.stroke(tin, with: .color(ink), style: line)

        // crust: scalloped rim
        let cx = 75.0, cy = 145.0
        var crust = Path()
        let n = 240, bumps = 30.0
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let s = pow(abs(sin(a * bumps / 2)), 0.6)
            let rx = 62 + 2.6 * s, ry = 18 + 2.0 * s
            let p = CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            if i == 0 { crust.move(to: p) } else { crust.addLine(to: p) }
        }
        crust.closeSubpath()
        ctx.fill(crust, with: .linearGradient(Gradient(colors: [crustTop, crustBot]), startPoint: CGPoint(x: 0, y: 125), endPoint: CGPoint(x: 0, y: 166)))
        // rim shading on the front lip
        var front = ctx
        front.clip(to: crust)
        front.fill(Path(ellipseIn: CGRect(x: 10, y: 150, width: 130, height: 22)), with: .color(crustLine.opacity(0.25)))
        ctx.stroke(crust, with: .color(ink), style: line)

        // filling
        let fillRect = CGRect(x: 25, y: 133, width: 100, height: 22)
        let fillPath = Path(ellipseIn: fillRect)
        ctx.fill(fillPath, with: .linearGradient(Gradient(colors: [fillTop, fillBot]), startPoint: CGPoint(x: 0, y: 133), endPoint: CGPoint(x: 0, y: 155)))

        // woven lattice: strips with outlines, alternating over/under
        var lat = ctx
        lat.clip(to: fillPath)
        let hY: [CGFloat] = [139, 149]
        let diag: [CGFloat] = [36, 56, 76, 96, 116]       // x at y = 144
        let slope: CGFloat = 0.55                          // dx per dy
        func hStrip(_ g: inout GraphicsContext, _ y: CGFloat) {
            var p = Path(); p.move(to: CGPoint(x: 20, y: y)); p.addLine(to: CGPoint(x: 130, y: y + 1.5))
            g.stroke(p, with: .color(ink.opacity(0.8)), lineWidth: 6.4)
            g.stroke(p, with: .color(crustTop), lineWidth: 5)
            var hl = Path(); hl.move(to: CGPoint(x: 20, y: y - 1)); hl.addLine(to: CGPoint(x: 130, y: y + 0.5))
            g.stroke(hl, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
        func dStrip(_ g: inout GraphicsContext, _ x: CGFloat) {
            var p = Path()
            p.move(to: CGPoint(x: x - 14 * slope, y: 158)); p.addLine(to: CGPoint(x: x + 14 * slope, y: 130))
            g.stroke(p, with: .color(ink.opacity(0.8)), lineWidth: 6.4)
            g.stroke(p, with: .color(crustTop), lineWidth: 5)
        }
        for y in hY { hStrip(&lat, y) }
        for x in diag { dStrip(&lat, x) }
        // re-lay horizontal strips on top at alternating crossings to make the weave
        for (i, x) in diag.enumerated() {
            for (j, y) in hY.enumerated() where (i + j) % 2 == 0 {
                let crossX = x - (y - 144) * slope
                var g = lat
                g.clip(to: Path(CGRect(x: crossX - 5.5, y: y - 4, width: 11, height: 8)))
                hStrip(&g, y)
            }
        }
        ctx.stroke(fillPath, with: .color(crustLine), lineWidth: 1.6)
    }

    // MARK: Parts

    static func drawArm(in ctx: inout GraphicsContext, from start: CGPoint, side: CGFloat, wave: Double, line: StrokeStyle) {
        let lift = CGFloat(wave)
        let end = CGPoint(x: start.x + side * 30, y: start.y - 30 - lift)
        var p = Path()
        p.move(to: start)
        p.addCurve(to: end,
                   control1: CGPoint(x: start.x + side * 16, y: start.y + 10),
                   control2: CGPoint(x: end.x + side * 1, y: end.y + 20))
        ctx.stroke(p, with: .color(ink), style: line)
        // curly loop hand (like a little "ℓ")
        var loop = Path()
        loop.move(to: end)
        loop.addCurve(to: CGPoint(x: end.x - side * 1, y: end.y - 9),
                      control1: CGPoint(x: end.x + side * 6, y: end.y - 2),
                      control2: CGPoint(x: end.x + side * 5, y: end.y - 10))
        loop.addCurve(to: CGPoint(x: end.x - side * 2.5, y: end.y + 1),
                      control1: CGPoint(x: end.x - side * 6, y: end.y - 8),
                      control2: CGPoint(x: end.x - side * 6, y: end.y - 1))
        ctx.stroke(loop, with: .color(ink), style: line)
    }

    static func drawSparkle(in ctx: inout GraphicsContext, at c: CGPoint, size: Double, angle: Double) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(angle))
        var p = Path()
        let s = CGFloat(size), k = s * 0.18
        p.move(to: CGPoint(x: 0, y: -s))
        p.addQuadCurve(to: CGPoint(x: s, y: 0), control: CGPoint(x: k, y: -k))
        p.addQuadCurve(to: CGPoint(x: 0, y: s), control: CGPoint(x: k, y: k))
        p.addQuadCurve(to: CGPoint(x: -s, y: 0), control: CGPoint(x: -k, y: k))
        p.addQuadCurve(to: CGPoint(x: 0, y: -s), control: CGPoint(x: -k, y: -k))
        g.fill(p, with: .color(gold))
        g.stroke(p, with: .color(PetDrawing.c(0xC9971E)), lineWidth: 0.5)
    }

    static func drawFace(in ctx: inout GraphicsContext, t: Double, mood: Mood) {
        let blinking = t.truncatingRemainder(dividingBy: 4.3) < 0.12 && mood != .sleeping
        let look: CGPoint = mood == .thinking ? CGPoint(x: 2.5, y: -3) : CGPoint(x: CGFloat(sin(t * 0.4) * 1.2), y: 0)
        let brow = StrokeStyle(lineWidth: 1.6, lineCap: .round)

        // little dash eyebrows
        for (a, b) in [(CGPoint(x: 59, y: 52.5), CGPoint(x: 62, y: 52.5)), (CGPoint(x: 90.5, y: 53), CGPoint(x: 93.5, y: 53))] {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(ink), style: brow)
        }

        let lc = CGPoint(x: 62, y: 74), rc = CGPoint(x: 93, y: 76)
        if mood == .sleeping || blinking {
            for (c, w) in [(lc, 10.0), (rc, 8.5)] {
                var p = Path()
                p.move(to: CGPoint(x: c.x - w, y: c.y))
                p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x, y: c.y + 6))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
            }
        } else {
            // left: big round eye
            ctx.fill(Path(ellipseIn: CGRect(x: lc.x - 11, y: lc.y - 12, width: 22, height: 24)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: lc.x - 7 + look.x, y: lc.y - 9 + look.y, width: 12, height: 12)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: lc.x - 0.5 + look.x, y: lc.y + 5 + look.y, width: 3.4, height: 3.4)), with: .color(.white))
            // right: rounded-square eye
            let re = CGRect(x: rc.x - 9.5, y: rc.y - 10.5, width: 19, height: 21)
            ctx.fill(Path(roundedRect: re, cornerRadius: 4.5), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: rc.x - 6 + look.x, y: rc.y - 7.5 + look.y, width: 9, height: 9)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: rc.x + 0.5 + look.x, y: rc.y + 4.5 + look.y, width: 2.6, height: 2.6)), with: .color(.white))
        }

        // blush with little hatch marks
        for x in [50.5, 101.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: 88, width: 9, height: 4.5)), with: .color(blush.opacity(0.8)))
            for dx in [2.6, 5.2] {
                var h = Path()
                h.move(to: CGPoint(x: x + dx, y: 91.5)); h.addLine(to: CGPoint(x: x + dx + 1.6, y: 88.5))
                ctx.stroke(h, with: .color(PetDrawing.c(0xD9706F)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }

        // mouth on the split line
        let open: CGFloat
        switch mood {
        case .talking: open = CGFloat(abs(sin(t * 11))) * 4
        case .excited: open = 4
        default: open = 0
        }
        if open > 0.5 {
            let r = CGRect(x: 73, y: 85, width: 8, height: open + 1.5)
            ctx.fill(Path(ellipseIn: r), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 75, y: r.maxY - 2, width: 4, height: 1.6)), with: .color(PetDrawing.c(0xE07A7A)))
        } else {
            var m = Path()
            m.move(to: CGPoint(x: 72.5, y: 84.5))
            m.addQuadCurve(to: CGPoint(x: 78, y: 85.5), control: CGPoint(x: 74.5, y: 90))
            ctx.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }
}
