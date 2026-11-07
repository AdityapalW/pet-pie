import AppKit
import SpriteKit
import SwiftUI

// Let it snow: a click-through overlay on every screen. Snow falls over the whole desktop,
// piles up on the top edge of your windows, and little Santas sit in the drifts.
// Click a Santa and it kicks a snowball off the edge; the snowball shatters where it lands.

enum SnowIntensity: Int, CaseIterable, Identifiable {
    case light, snowy, blizzard
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .light: return "Light flurries"
        case .snowy: return "Snowy"
        case .blizzard: return "Blizzard"
        }
    }
    /// Flakes on a ~1470×956 screen; scaled by screen area.
    var flakes: Int {
        switch self {
        case .light: return 140
        case .snowy: return 300
        case .blizzard: return 560
        }
    }
    var wind: CGFloat {
        switch self {
        case .light: return 4
        case .snowy: return 12
        case .blizzard: return 55
        }
    }
    var speed: CGFloat {
        switch self {
        case .light: return 0.85
        case .snowy: return 1
        case .blizzard: return 1.45
        }
    }
}

/// A normal app window on screen, in CoreGraphics global coordinates (origin top-left of the main display).
struct SnowWindow {
    let id: CGWindowID
    let frame: CGRect

    /// Front-to-back list of ordinary windows. Only bounds are read, so no Screen Recording permission is needed.
    static func onScreen() -> [SnowWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let n = d[kCGWindowNumber as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.width >= 120, r.height >= 60
            else { return nil }
            return SnowWindow(id: CGWindowID(n), frame: r)
        }
    }

    /// Whether a window still exists at all (minimised or on another Space counts as existing).
    static func exists(_ id: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return !info.isEmpty
    }
}

// MARK: - Controller

@MainActor
final class SnowController: ObservableObject {
    @Published private(set) var isOn = false
    @Published var intensity: SnowIntensity {
        didSet { UserDefaults.standard.set(intensity.rawValue, forKey: "snowIntensity") }
    }
    @Published var santas: Bool {
        didSet {
            UserDefaults.standard.set(santas, forKey: "snowSantas")
            if santas { scenes.forEach { $0.resetFocus() } } else { scenes.forEach { $0.dismissSantas() } }
        }
    }
    weak var pet: PetState?

    private var panels: [NSPanel] = []
    private var scenes: [SnowScene] { panels.compactMap { ($0.contentView as? SKView)?.scene as? SnowScene } }
    private var windowCache: [SnowWindow] = []
    private var windowCacheTime: TimeInterval = -1
    private var screenObserver: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        intensity = SnowIntensity(rawValue: d.object(forKey: "snowIntensity") as? Int ?? 1) ?? .snowy
        santas = d.object(forKey: "snowSantas") as? Bool ?? true
    }

    /// Resume snowing if it was on when Pi last quit.
    func restore() {
        if UserDefaults.standard.bool(forKey: "snowOn") { setOn(true, announce: false) }
    }

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool, announce: Bool = true) {
        guard on != isOn else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: "snowOn")
        if on {
            if panels.isEmpty { buildPanels() }
            scenes.forEach { $0.snowing = true }
            if announce { pet?.say("Let it snow! ❄️", mood: .excited, seconds: 3) }
        } else {
            scenes.forEach { $0.snowing = false }
            if announce { pet?.say("Melting the snow… ☀️", seconds: 3) }
        }
    }

    /// Knock all the piled-up snow off every window.
    func shakeOff() { scenes.forEach { $0.shakeOffAll() } }

    /// Window list shared by all screens, refreshed at most ~30 times a second.
    func windows(at time: TimeInterval) -> [SnowWindow] {
        if time - windowCacheTime > 0.033 || time < windowCacheTime {
            windowCache = SnowWindow.onScreen()
            windowCacheTime = time
        }
        return windowCache
    }

    /// Called by a scene once snow is off and everything on it has melted away.
    func sceneFinished() {
        guard !isOn, scenes.allSatisfy(\.isIdle) else { return }
        tearDown()
    }

    private func buildPanels() {
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar                       // above windows and the menu bar, below menus
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.ignoresMouseEvents = true                // click-through, except right over a Santa
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let view = SnowView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.allowsTransparency = true
            view.ignoresSiblingOrder = true
            view.preferredFramesPerSecond = 60
            let scene = SnowScene(size: screen.frame.size, screenFrame: screen.frame, controller: self)
            view.presentScene(scene)
            p.contentView = view
            p.setFrame(screen.frame, display: false)
            p.orderFrontRegardless()
            panels.append(p)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        tearDown()
        if isOn {
            buildPanels()
            scenes.forEach { $0.snowing = true }
        }
    }

    private func tearDown() {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        for p in panels {
            (p.contentView as? SKView)?.presentScene(nil)
            p.orderOut(nil)
        }
        panels = []
    }
}

final class SnowView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Pieces

private let spacing: CGFloat = 3

/// Snow lying on top of one window (or along the bottom of the screen for id 0).
@MainActor
final class SnowPile {
    let id: CGWindowID
    var rect: CGRect                 // window frame in scene coordinates
    var cols: [CGFloat]              // snow height every `spacing` points
    var visible: [Bool]              // false where another window covers this edge
    var maxH: CGFloat
    var hidden = false               // window minimised / on another Space
    let node = SKShapeNode()
    private let shadow = SKShapeNode()
    var dirty = true

    init(id: CGWindowID, rect: CGRect, maxH: CGFloat) {
        self.id = id
        self.rect = rect
        self.maxH = maxH
        let n = SnowPile.count(rect.width)
        cols = Array(repeating: 0, count: n)
        visible = Array(repeating: true, count: n)
        node.fillColor = .white
        node.fillTexture = SnowArt.drift
        node.strokeColor = NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.95, alpha: 0.8)
        node.lineWidth = 0.8
        node.isAntialiased = true
        node.zPosition = 2
        shadow.fillColor = NSColor(white: 0, alpha: 0.16)
        shadow.strokeColor = .clear
        shadow.position = CGPoint(x: 0.6, y: -1.4)
        shadow.zPosition = -1
        node.addChild(shadow)
        node.position = CGPoint(x: rect.minX, y: rect.maxY)
    }

    static func count(_ w: CGFloat) -> Int { max(2, Int(w / spacing) + 1) }
    var top: CGFloat { rect.maxY }
    var isEmpty: Bool { !cols.contains { $0 > 0.05 } }

    func index(_ x: CGFloat) -> Int { min(cols.count - 1, max(0, Int((x / spacing).rounded()))) }

    func isVisible(at x: CGFloat) -> Bool { !hidden && x >= 0 && x <= rect.width && visible[index(x)] }

    /// Snow height at `x` points from the window's left edge.
    func height(at x: CGFloat) -> CGFloat { SnowPile.sample(cols, x) }

    static func sample(_ cols: [CGFloat], _ x: CGFloat) -> CGFloat {
        let f = x / spacing
        guard f >= 0, cols.count > 1 else { return 0 }
        let i = min(cols.count - 2, Int(f))
        let t = min(1, f - CGFloat(i))
        return cols[i] * (1 - t) + cols[i + 1] * t
    }

    /// Snow can't pile up right at the rounded window corners, and stays low at the screen top.
    func cap(_ i: Int) -> CGFloat {
        let x = CGFloat(i) * spacing
        let t = max(0, min(1, min(x, rect.width - x) / 22))
        return maxH * t * t * (3 - 2 * t)
    }

    func add(at x: CGFloat, amount: CGFloat) {
        let c = index(x)
        let boost = 1 + 2.5 * max(0, 1 - cols[c] / 3)      // a thin layer settles fast, then it builds slowly
        let amount = amount * boost
        let kernel: [CGFloat] = [0.08, 0.2, 0.4, 0.65, 0.88, 1, 0.88, 0.65, 0.4, 0.2, 0.08]
        for (k, w) in kernel.enumerated() {
            let i = c + k - 5
            guard i >= 0, i < cols.count else { continue }
            cols[i] = min(cap(i), cols[i] + amount * w)
        }
        dirty = true
    }

    /// Scoop snow off the columns between two x positions (a rolling snowball). Returns how much was taken.
    func scoop(from x0: CGFloat, to x1: CGFloat) -> CGFloat {
        var a = index(min(x0, x1)), b = index(max(x0, x1))
        a = max(0, a - 1); b = min(cols.count - 1, b + 1)
        var taken: CGFloat = 0
        for i in a...b {
            let t = cols[i] * 0.45
            cols[i] -= t
            taken += t
        }
        dirty = true
        return taken
    }

    func melt(_ dt: CGFloat) {
        guard !isEmpty else { return }
        for i in cols.indices { cols[i] = max(0, cols[i] - 1.3 * dt) }
        dirty = true
    }

    func resize(to r: CGRect) {
        let old = cols, scale = rect.width / max(1, r.width)
        rect = r
        let n = SnowPile.count(r.width)
        cols = (0..<n).map { SnowPile.sample(old, CGFloat($0) * spacing * scale) }
        visible = Array(repeating: true, count: n)
        for i in cols.indices { cols[i] = min(cols[i], cap(i)) }
        dirty = true
    }

    /// `front` = rects of windows in front of this one.
    func updateVisibility(front: [CGRect]) {
        var changed = false
        for i in cols.indices {
            let x = rect.minX + CGFloat(i) * spacing
            let below = CGPoint(x: x, y: top - 2), above = CGPoint(x: x, y: top + 3)
            let v = !front.contains { $0.contains(below) || $0.contains(above) }
            if v != visible[i] { visible[i] = v; changed = true }
        }
        if changed { dirty = true }
    }

    /// Let steep steps slide a little so the drift looks soft, then rebuild the shape.
    func rebuildPath() {
        for _ in 0..<5 where cols.count > 2 {
            for i in 0..<(cols.count - 1) {
                let d = cols[i] - cols[i + 1]
                guard abs(d) > 0.8 else { continue }
                let m = (abs(d) - 0.8) * 0.3 * (d > 0 ? 1 : -1)
                cols[i] -= m
                cols[i + 1] += m
            }
        }
        for i in cols.indices { cols[i] = min(cols[i], cap(i)) }

        let path = CGMutablePath()
        var i = 0
        while i < cols.count {
            guard !hidden, visible[i], cols[i] > 0.12 else { i += 1; continue }
            var j = i
            while j + 1 < cols.count, visible[j + 1], cols[j + 1] > 0.12 { j += 1 }
            let x0 = CGFloat(i) * spacing, x1 = CGFloat(j) * spacing
            path.move(to: CGPoint(x: x0 - 1, y: -0.5))
            path.addLine(to: CGPoint(x: x0, y: cols[i]))
            if j > i {
                for k in i..<j {
                    let p = CGPoint(x: CGFloat(k) * spacing, y: cols[k])
                    let q = CGPoint(x: CGFloat(k + 1) * spacing, y: cols[k + 1])
                    path.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
                }
            }
            path.addLine(to: CGPoint(x: x1, y: cols[j]))
            path.addLine(to: CGPoint(x: x1 + 1, y: -0.5))
            path.closeSubpath()
            i = j + 1
        }
        node.path = path
        shadow.path = path
        node.position = CGPoint(x: rect.minX, y: rect.maxY)
        dirty = false
    }
}

private struct Flake {
    let node: SKSpriteNode
    let depth: CGFloat      // 0 = far away (falls past everything) … 1 = close (lands on windows)
    let vy: CGFloat
    let phase: CGFloat
    let swayFreq: CGFloat
    let spin: CGFloat
    let lands: Bool         // close enough to settle on windows
    var leaving = false
}

@MainActor
final class Santa {
    let node: SKSpriteNode
    let windowID: CGWindowID
    var fx: CGFloat
    let seed = CGFloat.random(in: 0...10)
    var hovered = false
    var happyUntil: TimeInterval = 0
    var hopStart: TimeInterval = -10
    var cooldownUntil: TimeInterval = 0
    var falling = false
    var leaving = false
    var vy: CGFloat = 0

    init(node: SKSpriteNode, windowID: CGWindowID, fx: CGFloat) {
        self.node = node
        self.windowID = windowID
        self.fx = fx
    }
}

@MainActor
final class Snowball {
    let node: SKSpriteNode
    var r: CGFloat
    var rollingOn: CGWindowID?      // nil once it's in the air
    var fx: CGFloat = 0
    var dir: CGFloat = 1
    var speed: CGFloat = 60
    var vel = CGVector.zero

    init(node: SKSpriteNode, r: CGFloat) {
        self.node = node
        self.r = r
    }
}

private struct Bit {
    let node: SKSpriteNode
    var vel: CGVector
    var life: CGFloat
    let spin: CGFloat
}

// MARK: - Scene

final class SnowScene: SKScene {
    let screenFrame: CGRect
    weak var controller: SnowController?

    var snowing = false {
        didSet {
            if snowing { reportedIdle = false; if snowStart == nil { snowStart = lastTime } }
            else { snowStart = nil; dismissSantas() }
        }
    }

    private var flakes: [Flake] = []
    private var piles: [CGWindowID: SnowPile] = [:]
    private var ground: SnowPile!
    private var order: [(id: CGWindowID, rect: CGRect)] = []   // front-to-back, scene coordinates
    private var santas: [Santa] = []
    private var balls: [Snowball] = []
    private var bits: [Bit] = []

    private var lastTime: TimeInterval = 0
    private var lastWindows: TimeInterval = 0
    private var lastPaths: TimeInterval = 0
    private var lastSantaCheck: TimeInterval = 0
    private var snowStart: TimeInterval?
    private var reportedIdle = false
    private var clickable = false
    private var focusID: CGWindowID?
    private var lastSparkle: TimeInterval = 0

    private lazy var flakeTex = SnowArt.flakeTexture()
    private lazy var crystalTex = SnowArt.crystalTexture()
    private lazy var sparkleTex = SnowArt.sparkleTexture()
    private lazy var ballTex = SnowArt.ballTexture()
    private lazy var santaTex: [SantaPose: SKTexture] = Dictionary(uniqueKeysWithValues: SantaPose.allCases.map { ($0, SnowArt.santaTexture($0)) })

    init(size: CGSize, screenFrame: CGRect, controller: SnowController) {
        self.screenFrame = screenFrame
        self.controller = controller
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        ground = SnowPile(id: 0, rect: CGRect(x: 0, y: 0, width: size.width, height: 0), maxH: 9)
        addChild(ground.node)
    }

    var isIdle: Bool {
        !snowing && flakes.isEmpty && balls.isEmpty && bits.isEmpty && santas.isEmpty
            && ground.isEmpty && piles.values.allSatisfy(\.isEmpty)
    }

    private var intensity: SnowIntensity { controller?.intensity ?? .snowy }
    private var allPiles: [SnowPile] { Array(piles.values) + [ground] }

    // MARK: Frame

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(1.0 / 20, max(0, currentTime - lastTime)))
        lastTime = currentTime
        if snowing && snowStart == nil { snowStart = currentTime }

        if currentTime - lastWindows > 0.033 {
            lastWindows = currentTime
            refreshWindows(currentTime)
        }

        updateFlakes(dt, currentTime)
        updateBalls(dt)
        updateBits(dt)
        updateSantas(dt, currentTime)

        if !snowing { allPiles.forEach { $0.melt(dt) } }
        if currentTime - lastSparkle > 0.18 {
            lastSparkle = currentTime
            twinkle()
        }

        if currentTime - lastPaths > 0.1 {
            lastPaths = currentTime
            for p in allPiles where p.dirty { p.rebuildPath() }
        }

        if snowing, controller?.santas == true, currentTime - lastSantaCheck > 4 {
            lastSantaCheck = currentTime
            maybeSpawnSanta(currentTime)
        }

        updateMouse()

        if !snowing && !reportedIdle && isIdle {
            reportedIdle = true
            DispatchQueue.main.async { [weak controller] in controller?.sceneFinished() }
        }
    }

    // MARK: Windows

    private func refreshWindows(_ t: TimeInterval) {
        guard let controller else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let bounds = CGRect(origin: .zero, size: size)
        order = controller.windows(at: t).compactMap { w in
            let cocoa = CGRect(x: w.frame.minX, y: mainHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
            let local = cocoa.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            return local.intersects(bounds) ? (w.id, local) : nil
        }

        var seen = Set<CGWindowID>()
        for (idx, w) in order.enumerated() {
            seen.insert(w.id)
            let nearTop = w.rect.maxY > size.height - 44     // maximised window: keep the menu bar readable
            let maxH: CGFloat = nearTop ? 6 : min(18, max(8, w.rect.width * 0.02))
            let pile: SnowPile
            if let existing = piles[w.id] {
                pile = existing
                if pile.hidden { pile.hidden = false; pile.dirty = true }
                let moved = hypot(w.rect.minX - pile.rect.minX, w.rect.maxY - pile.rect.maxY)
                if abs(w.rect.width - pile.rect.width) > 0.5 { pile.resize(to: w.rect) } else { pile.rect = w.rect }
                if moved > 60 { spill(pile, keep: 0.65, maxClumps: 8) }   // yanked hard: some snow flies off
            } else {
                guard snowing else { continue }
                pile = SnowPile(id: w.id, rect: w.rect, maxH: maxH)
                piles[w.id] = pile
                addChild(pile.node)
            }
            pile.maxH = maxH
            pile.node.position = CGPoint(x: w.rect.minX, y: w.rect.maxY)
            pile.updateVisibility(front: order[..<idx].map(\.rect))
        }
        ground.updateVisibility(front: order.map(\.rect))

        // Focus changed (or snow just started): pop a Santa onto the focused window right away.
        let front = controller.windows(at: t).first?.id
        if snowing, controller.santas, let front, front != focusID {
            focusID = front
            if order.contains(where: { $0.id == front }) { summonSanta(on: front, t) }
        }

        for (id, pile) in piles where !seen.contains(id) && !pile.hidden {
            if SnowWindow.exists(id) {
                pile.hidden = true             // minimised or on another Space: keep the snow for later
                pile.dirty = true
            } else {
                spill(pile, keep: 0, maxClumps: 26)   // window closed: everything falls
                pile.node.removeFromParent()
                piles[id] = nil
            }
        }
    }

    private func pile(_ id: CGWindowID) -> SnowPile? { id == 0 ? ground : piles[id] }

    /// The first snow surface crossed between two heights at `x`, front-most window first, then the ground.
    private func surfaceHit(x: CGFloat, fromY y0: CGFloat, toY y1: CGFloat) -> (SnowPile, CGFloat)? {
        for w in order where x >= w.rect.minX && x <= w.rect.maxX {
            guard let p = piles[w.id], !p.hidden else { continue }
            let fx = x - w.rect.minX
            let s = w.rect.maxY + p.height(at: fx)
            if y0 >= s && y1 < s && p.isVisible(at: fx) { return (p, s) }
        }
        let s = ground.height(at: x)
        if y0 >= s && y1 < s && ground.isVisible(at: x) { return (ground, s) }
        return nil
    }

    // MARK: Flakes

    private func newFlake(initial: Bool) -> Flake {
        let roll = CGFloat.random(in: 0...1)
        let depth = CGFloat.random(in: 0...1)
        let node: SKSpriteNode
        let vy: CGFloat
        var spin: CGFloat = 0
        var lands = depth > 0.5
        if roll < 0.04 {
            // Big, soft, out-of-focus flake drifting right past the "camera".
            node = SKSpriteNode(texture: flakeTex)
            let d = CGFloat.random(in: 14...24)
            node.size = CGSize(width: d, height: d)
            node.alpha = .random(in: 0.16...0.28)
            node.zPosition = 11
            vy = .random(in: 95...130)
            lands = false
        } else if depth > 0.72 && roll < 0.4 {
            // Close-up crystal you can actually see the arms of.
            node = SKSpriteNode(texture: crystalTex)
            let d = 6.5 + depth * 6
            node.size = CGSize(width: d, height: d)
            node.alpha = 0.9
            node.zPosition = 6
            node.zRotation = .random(in: 0...(2 * .pi))
            spin = .random(in: -1.4...1.4)
            vy = 40 + depth * 34 + .random(in: 0...10)
        } else {
            node = SKSpriteNode(texture: flakeTex)
            let d = 1.8 + depth * 5
            node.size = CGSize(width: d, height: d)
            node.alpha = 0.45 + depth * 0.5
            node.zPosition = depth > 0.5 ? 5 : 1
            vy = 22 + depth * 46 + .random(in: 0...10)
        }
        node.position = CGPoint(x: .random(in: -20...(size.width + 20)),
                                y: initial ? .random(in: size.height * 0.15...size.height * 1.2) : size.height + .random(in: 4...40))
        if initial {
            let a = node.alpha
            node.alpha = 0
            node.run(.fadeAlpha(to: a, duration: 0.8))
        }
        addChild(node)
        return Flake(node: node, depth: depth, vy: vy, phase: .random(in: 0...(2 * .pi)),
                     swayFreq: .random(in: 0.5...1.6), spin: spin, lands: lands)
    }

    private func updateFlakes(_ dt: CGFloat, _ t: TimeInterval) {
        let inten = intensity
        let target = snowing ? Int(CGFloat(inten.flakes) * (size.width * size.height) / (1470 * 956)) : 0
        if flakes.count < target {
            let initial = flakes.isEmpty || t - (snowStart ?? t) < 1.5
            for _ in 0..<min(12, target - flakes.count) { flakes.append(newFlake(initial: initial)) }
        }
        let gust = inten.wind * (1 + 0.6 * CGFloat(sin(t * 0.31)))
        var alive = flakes.count
        for i in flakes.indices {
            var f = flakes[i]
            let old = f.node.position
            var p = old
            p.y -= f.vy * inten.speed * dt
            p.x += (CGFloat(sin(t * Double(f.swayFreq) + Double(f.phase))) * (8 + 16 * f.depth) + gust * (0.5 + f.depth)) * dt

            var respawn = false
            if f.lands, let (pile, _) = surfaceHit(x: p.x, fromY: old.y, toY: p.y) {
                pile.add(at: pile.id == 0 ? p.x : p.x - pile.rect.minX, amount: 1.8 * f.depth)
                respawn = true
            } else if p.y < -8 {
                respawn = true
            }
            if p.x < -30 { p.x += size.width + 60 } else if p.x > size.width + 30 { p.x -= size.width + 60 }

            if respawn {
                if alive > target {
                    f.leaving = true                 // snow stopping / getting lighter: let this one go
                    alive -= 1
                } else {
                    p = CGPoint(x: .random(in: -20...(size.width + 20)) - gust * 3, y: size.height + .random(in: 4...30))
                }
            }
            f.node.position = p
            if f.spin != 0 { f.node.zRotation += f.spin * dt }
            flakes[i] = f
        }
        if alive < flakes.count {
            for f in flakes where f.leaving { f.node.removeFromParent() }
            flakes.removeAll(where: \.leaving)
        }
    }

    /// A tiny glint somewhere on a drift.
    private func twinkle() {
        let deep = allPiles.filter { !$0.hidden && $0.cols.contains { $0 > 3 } }
        guard let p = deep.randomElement() else { return }
        let spots = p.cols.indices.filter { p.cols[$0] > 2.5 && p.visible[$0] }
        guard let i = spots.randomElement() else { return }
        let x = CGFloat(i) * spacing
        let node = SKSpriteNode(texture: sparkleTex)
        let d = CGFloat.random(in: 5...9)
        node.size = CGSize(width: d, height: d)
        node.position = CGPoint(x: p.rect.minX + x, y: p.top + p.cols[i] * .random(in: 0.55...0.95))
        node.zPosition = 4
        node.alpha = 0
        node.setScale(0.3)
        addChild(node)
        node.run(.sequence([.group([.fadeIn(withDuration: 0.25), .scale(to: 1, duration: 0.25), .rotate(byAngle: 0.6, duration: 0.7)]),
                            .group([.fadeOut(withDuration: 0.45), .scale(to: 0.3, duration: 0.45)]),
                            .removeFromParent()]))
    }

    // MARK: Snowballs & bits

    private func makeBall(r: CGFloat, at p: CGPoint) -> Snowball {
        let node = SKSpriteNode(texture: ballTex)
        node.size = CGSize(width: r * 2, height: r * 2)
        node.position = p
        node.zPosition = 8
        addChild(node)
        let b = Snowball(node: node, r: r)
        balls.append(b)
        return b
    }

    /// A clump of snow that falls off something and breaks where it lands.
    private func spawnClump(at p: CGPoint, r: CGFloat) {
        let b = makeBall(r: r, at: p)
        b.vel = CGVector(dx: .random(in: -40...40), dy: .random(in: 0...70))
        b.node.zRotation = .random(in: 0...(2 * .pi))
    }

    private func spill(_ pile: SnowPile, keep: CGFloat, maxClumps: Int) {
        guard !pile.hidden else { return }
        let spots = pile.cols.indices.filter { pile.cols[$0] > 2 && pile.visible[$0] }.shuffled()
        for i in spots.prefix(maxClumps) {
            let h = pile.cols[i]
            spawnClump(at: CGPoint(x: pile.rect.minX + CGFloat(i) * spacing, y: pile.top + h * 0.5), r: min(6.5, 1.8 + h * 0.35))
        }
        for i in pile.cols.indices { pile.cols[i] *= keep }
        pile.dirty = true
    }

    func shakeOffAll() {
        for p in piles.values { spill(p, keep: 0, maxClumps: 26) }
        for i in ground.cols.indices { ground.cols[i] = 0 }
        ground.dirty = true
    }

    private func updateBalls(_ dt: CGFloat) {
        var done: [ObjectIdentifier] = []
        for b in balls {
            if let id = b.rollingOn {
                guard let p = pile(id), !p.hidden, piles[id] != nil || id == 0 else {
                    b.rollingOn = nil
                    b.vel = CGVector(dx: b.dir * b.speed, dy: 20)
                    continue
                }
                b.speed = min(320, b.speed + 240 * dt)
                let dx = b.dir * b.speed * dt
                let taken = p.scoop(from: b.fx, to: b.fx + dx)
                b.fx += dx
                b.r = min(16, b.r + taken * 0.03)
                b.node.size = CGSize(width: b.r * 2, height: b.r * 2)
                b.node.zRotation -= b.dir * dx / b.r
                b.node.position = CGPoint(x: p.rect.minX + b.fx, y: p.top + p.height(at: b.fx) * 0.5 + b.r * 0.85)
                if b.fx < -b.r * 0.3 || b.fx > p.rect.width + b.r * 0.3 {
                    b.rollingOn = nil                       // off the edge!
                    b.vel = CGVector(dx: b.dir * b.speed * 0.8, dy: 50)
                }
                continue
            }
            let old = b.node.position
            b.vel.dy -= 1500 * dt
            let pos = CGPoint(x: old.x + b.vel.dx * dt, y: old.y + b.vel.dy * dt)
            b.node.position = pos
            b.node.zRotation -= b.vel.dx * dt / max(3, b.r)
            if let (pile, s) = surfaceHit(x: pos.x, fromY: old.y - b.r, toY: pos.y - b.r) {
                shatter(at: CGPoint(x: pos.x, y: s), r: b.r, onto: pile)
                done.append(ObjectIdentifier(b))
            } else if pos.y < -60 || pos.x < -80 || pos.x > size.width + 80 {
                done.append(ObjectIdentifier(b))
            }
        }
        if !done.isEmpty {
            for b in balls where done.contains(ObjectIdentifier(b)) { b.node.removeFromParent() }
            balls.removeAll { done.contains(ObjectIdentifier($0)) }
        }
    }

    private func shatter(at p: CGPoint, r: CGFloat, onto pile: SnowPile) {
        pile.add(at: pile.id == 0 ? p.x : p.x - pile.rect.minX, amount: r * 0.12)
        let n = Int(8 + r * 1.3)
        for _ in 0..<n {
            let node = SKSpriteNode(texture: ballTex)
            let d = CGFloat.random(in: 1.6...max(2.5, r * 0.5))
            node.size = CGSize(width: d, height: d)
            node.position = CGPoint(x: p.x + .random(in: -r * 0.5...r * 0.5), y: p.y + .random(in: 0...r * 0.6))
            node.zPosition = 9
            addChild(node)
            let a = CGFloat.random(in: 0.12 * .pi...0.88 * .pi)
            let v = CGFloat.random(in: 70...(150 + r * 9))
            bits.append(Bit(node: node, vel: CGVector(dx: cos(a) * v, dy: sin(a) * v), life: .random(in: 0.55...1.05), spin: .random(in: -9...9)))
        }
        let puff = SKSpriteNode(texture: flakeTex)
        puff.size = CGSize(width: r * 2.2, height: r * 2.2)
        puff.position = CGPoint(x: p.x, y: p.y + r * 0.4)
        puff.alpha = 0.75
        puff.zPosition = 9
        addChild(puff)
        puff.run(.sequence([.group([.scale(to: 2.6, duration: 0.32), .fadeOut(withDuration: 0.32)]), .removeFromParent()]))
        if r >= 7 { SnowArt.play("Pop", volume: 0.18) }
    }

    private func updateBits(_ dt: CGFloat) {
        guard !bits.isEmpty else { return }
        for i in bits.indices {
            var b = bits[i]
            b.vel.dy -= 1100 * dt
            var p = b.node.position
            p.x += b.vel.dx * dt
            p.y += b.vel.dy * dt
            if p.y < 0 { p.y = 0; b.vel.dy *= -0.3; b.vel.dx *= 0.6 }
            b.node.position = p
            b.node.zRotation += b.spin * dt
            b.life -= dt
            b.node.alpha = max(0, min(1, b.life * 2.5))
            bits[i] = b
        }
        for b in bits where b.life <= 0 { b.node.removeFromParent() }
        bits.removeAll { $0.life <= 0 }
    }

    // MARK: Santas

    private var activeSantas: [Santa] { santas.filter { !$0.leaving && !$0.falling } }

    /// Forget which window had focus, so the focused window gets a Santa again on the next refresh.
    func resetFocus() { focusID = nil }

    /// The focused (front-most) window always gets a Santa, right away.
    private func summonSanta(on id: CGWindowID, _ t: TimeInterval) {
        guard let p = piles[id], !p.hidden else { return }
        if let s = activeSantas.first(where: { $0.windowID == id }) {
            s.hopStart = t                       // already here: say hi
            s.happyUntil = t + 0.8
            return
        }
        let nearTop = p.top > size.height - 60
        // Sit right of centre (away from the traffic lights); on a maximised window stay clear of the menu bar items.
        let want = p.rect.width * (nearTop ? 0.4 : .random(in: 0.6...0.78))
        let spots = stride(from: CGFloat(30), through: p.rect.width - 30, by: spacing).filter { p.isVisible(at: $0) }
        guard let fx = spots.min(by: { abs($0 - want) < abs($1 - want) }) else { return }
        let s = spawnSanta(on: p, fx: fx, t)
        say(s, ["Ho ho ho!", "Hi there!", "Merry Christmas!", "Snow day!"].randomElement()!)
        // Keep it to three: the one that's been around longest heads home.
        let others = activeSantas.filter { $0 !== s }
        if others.count > 2, let oldest = others.first { dismiss(oldest) }
    }

    private func maybeSpawnSanta(_ t: TimeInterval) {
        guard activeSantas.count < 3, let start = snowStart, t - start > 6 else { return }
        let taken = Set(santas.map(\.windowID))
        func mean(_ p: SnowPile) -> CGFloat {
            let v = p.cols.indices.filter { p.visible[$0] }
            return v.isEmpty ? 0 : v.reduce(0) { $0 + p.cols[$1] } / CGFloat(v.count)
        }
        let need: CGFloat = santas.isEmpty ? 1.0 : 3.0
        var candidates = order.compactMap { w -> SnowPile? in
            guard let p = piles[w.id], !taken.contains(w.id), w.rect.width >= 220,
                  w.rect.maxY < size.height - 60, mean(p) >= need else { return nil }
            return p
        }
        if candidates.isEmpty, !taken.contains(0), mean(ground) >= need { candidates = [ground] }
        guard let p = candidates.randomElement() else { return }
        let width = p.rect.width
        let spots = stride(from: CGFloat(40), through: width - 40, by: spacing).filter { p.isVisible(at: $0) }
        guard let fx = spots.randomElement() else { return }
        spawnSanta(on: p, fx: fx, t)
    }

    @discardableResult
    private func spawnSanta(on p: SnowPile, fx: CGFloat, _ t: TimeInterval) -> Santa {
        let node = SKSpriteNode(texture: santaTex[.idle])
        node.size = CGSize(width: 46, height: 46)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.1)
        node.zPosition = 6
        node.setScale(0)
        addChild(node)
        node.run(.sequence([.scale(to: 1.18, duration: 0.18), .scale(to: 0.94, duration: 0.08), .scale(to: 1, duration: 0.07)]))
        let s = Santa(node: node, windowID: p.id, fx: fx)
        santas.append(s)
        node.position = santaSpot(s, p, t)
        let puff = SKSpriteNode(texture: flakeTex)
        puff.size = CGSize(width: 30, height: 30)
        puff.position = node.position
        puff.zPosition = 7
        addChild(puff)
        puff.run(.sequence([.group([.scale(to: 2.2, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))
        return s
    }

    /// Little floating speech text above a Santa.
    private func say(_ s: Santa, _ text: String) {
        let label = SKLabelNode()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.2, blue: 0.17, alpha: 1),
            .strokeColor: NSColor.white,
            .strokeWidth: -4,
        ])
        label.position = CGPoint(x: s.node.position.x, y: s.node.position.y + 46)
        label.zPosition = 10
        addChild(label)
        label.run(.sequence([.group([.moveBy(x: 0, y: 18, duration: 1.0), .sequence([.wait(forDuration: 0.6), .fadeOut(withDuration: 0.4)])]),
                             .removeFromParent()]))
    }

    private func dismiss(_ s: Santa) {
        guard !s.leaving, !s.falling else { return }
        s.leaving = true
        s.node.texture = santaTex[.wave]
        s.node.run(.sequence([.wait(forDuration: 0.5), .scale(to: 0, duration: 0.22), .removeFromParent()]))
    }

    private func santaSpot(_ s: Santa, _ p: SnowPile, _ t: TimeInterval) -> CGPoint {
        let hopT = t - s.hopStart
        let hop = hopT < 0.38 ? CGFloat(sin(.pi * hopT / 0.38)) * 16 : 0
        return CGPoint(x: p.rect.minX + s.fx, y: p.top + p.height(at: s.fx) * 0.7 - 1 + hop)
    }

    func dismissSantas() {
        activeSantas.forEach(dismiss)
        focusID = nil
    }

    private func updateSantas(_ dt: CGFloat, _ t: TimeInterval) {
        for s in santas {
            if s.leaving { continue }
            if s.falling {
                s.vy -= 1300 * dt
                s.node.position.y += s.vy * dt
                s.node.zRotation += 4 * dt
                s.node.alpha -= dt * 0.9
                continue
            }
            guard let p = pile(s.windowID), piles[s.windowID] != nil || s.windowID == 0 else {
                s.falling = true                          // the window closed under Santa
                s.vy = 120
                continue
            }
            s.fx = min(max(s.fx, 16), p.rect.width - 16)
            s.node.position = santaSpot(s, p, t)
            // Shrink to fit when the window touches the top of the screen, so his hat isn't cut off.
            let room = size.height - (p.top + p.height(at: s.fx) * 0.7)
            let side = 46 * max(0.62, min(1, (room - 1) / 42))
            if abs(s.node.size.width - side) > 0.5 { s.node.size = CGSize(width: side, height: side) }
            let show = p.isVisible(at: s.fx)
            s.node.alpha += ((show ? 1 : 0) - s.node.alpha) * min(1, dt * 10)
            s.node.zRotation = CGFloat(sin(t * 1.7 + Double(s.seed))) * 0.04

            let blink = (t + Double(s.seed)).truncatingRemainder(dividingBy: 4.1) < 0.13
            let pose: SantaPose = t < s.happyUntil ? .happy : s.hovered ? .wave : blink ? .blink : .idle
            if s.node.texture !== santaTex[pose] { s.node.texture = santaTex[pose] }
        }
        let gone = santas.filter { ($0.falling && ($0.node.alpha <= 0 || $0.node.position.y < -60)) || ($0.leaving && $0.node.parent == nil) }
        if !gone.isEmpty {
            for s in gone { s.node.removeFromParent() }
            santas.removeAll { s in gone.contains { $0 === s } }
        }
    }

    private func poke(_ s: Santa) {
        let t = lastTime
        guard t >= s.cooldownUntil, let p = pile(s.windowID) else { return }
        s.cooldownUntil = t + 0.45
        s.hopStart = t
        s.happyUntil = t + 0.9
        SnowArt.play("Pop", volume: 0.3)
        say(s, ["Ho ho ho!", "Ho ho!", "Heads up!", "Wheee!"].randomElement()!)

        // Kick a snowball toward the nearer edge.
        let dir: CGFloat = s.fx < p.rect.width / 2 ? -1 : 1
        let r: CGFloat = 6
        let start = CGPoint(x: s.node.position.x + dir * 16, y: p.top + p.height(at: s.fx + dir * 16) * 0.5 + r)
        let b = makeBall(r: r, at: start)
        b.rollingOn = s.windowID
        b.fx = s.fx + dir * 16
        b.dir = dir
        b.speed = 70
    }

    // MARK: Mouse

    /// The overlay ignores the mouse except right over a Santa, so everything else stays clickable.
    private func updateMouse() {
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - screenFrame.minX, y: m.y - screenFrame.minY)
        var over = false
        for s in santas {
            let hit = !s.falling && !s.leaving && s.node.alpha > 0.5 && s.node.frame.insetBy(dx: -4, dy: -4).contains(local)
            s.hovered = hit
            over = over || hit
        }
        if over != clickable {
            clickable = over
            view?.window?.ignoresMouseEvents = !over
            if over { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if let s = santas.first(where: { !$0.falling && !$0.leaving && $0.node.frame.insetBy(dx: -4, dy: -4).contains(p) }) {
            poke(s)
        }
    }
}

// MARK: - Art

enum SantaPose: CaseIterable { case idle, blink, wave, happy }

@MainActor
enum SnowArt {
    static func play(_ name: String, volume: Float) {
        guard let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }

    /// Frosty vertical gradient for the drifts: bright on top, a cool blue shadow at the base.
    static let drift: SKTexture = {
        let img = NSImage(size: NSSize(width: 4, height: 64), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext,
                  let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [CGColor(red: 0.80, green: 0.87, blue: 0.96, alpha: 1),
                                              CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1),
                                              CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFArray,
                                     locations: [0, 0.35, 1])
            else { return false }
            cg.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: r.height), options: [])
            return true
        }
        return SKTexture(image: img)
    }()

    /// Six-armed snowflake crystal with little branches.
    static func crystalTexture() -> SKTexture {
        let img = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: r.midX, y: r.midY)
            cg.setLineCap(.round)
            cg.setShadow(offset: .zero, blur: 3, color: CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.9))
            cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                func pt(_ d: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d) }
                cg.setLineWidth(2.6)
                cg.move(to: c); cg.addLine(to: pt(19)); cg.strokePath()
                cg.setLineWidth(1.8)
                for (along, len) in [(CGFloat(8), CGFloat(6)), (13, 4.5)] {
                    let base = pt(along)
                    for side in [CGFloat(-1), 1] {
                        let b = a + side * .pi / 3.2
                        cg.move(to: base)
                        cg.addLine(to: CGPoint(x: base.x + cos(b) * len, y: base.y + sin(b) * len))
                    }
                }
                cg.strokePath()
            }
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            return true
        }
        return SKTexture(image: img)
    }

    /// Four-point glint for the drifts.
    static func sparkleTexture() -> SKTexture {
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: r.midX, y: r.midY), s: CGFloat = 15, k: CGFloat = 2.2
            cg.setShadow(offset: .zero, blur: 4, color: CGColor(red: 0.7, green: 0.85, blue: 1, alpha: 1))
            cg.move(to: CGPoint(x: c.x, y: c.y + s))
            cg.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
            cg.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x + k, y: c.y - k))
            cg.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
            cg.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x - k, y: c.y + k))
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fillPath()
            return true
        }
        return SKTexture(image: img)
    }

    /// Soft round flake (also used for puffs).
    static func flakeTexture() -> SKTexture {
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext,
                  let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.85), CGColor(gray: 1, alpha: 0)] as CFArray,
                                     locations: [0, 0.45, 1])
            else { return false }
            let c = CGPoint(x: r.midX, y: r.midY)
            cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r.width / 2, options: [])
            return true
        }
        return SKTexture(image: img)
    }

    /// Snowball with a little shading and speckles so you can see it roll.
    static func ballTexture() -> SKTexture {
        let img = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { r in
            guard let cg = NSGraphicsContext.current?.cgContext,
                  let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                              CGColor(red: 0.86, green: 0.91, blue: 0.96, alpha: 1)] as CFArray,
                                     locations: [0.2, 1])
            else { return false }
            let circle = r.insetBy(dx: 2, dy: 2)
            cg.saveGState()
            cg.addEllipse(in: circle)
            cg.clip()
            cg.drawRadialGradient(g, startCenter: CGPoint(x: r.midX - 7, y: r.midY + 8), startRadius: 0,
                                  endCenter: CGPoint(x: r.midX, y: r.midY), endRadius: r.width / 2, options: [.drawsAfterEndLocation])
            cg.setFillColor(CGColor(red: 0.74, green: 0.82, blue: 0.9, alpha: 0.9))
            for (x, y, d) in [(30.0, 14.0, 4.0), (14.0, 24.0, 3.0), (32.0, 30.0, 2.6), (22.0, 34.0, 2.2), (18.0, 12.0, 2.0)] {
                cg.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
            }
            cg.restoreGState()
            cg.setStrokeColor(CGColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 1))
            cg.setLineWidth(1.8)
            cg.strokeEllipse(in: circle)
            return true
        }
        return SKTexture(image: img)
    }

    static func santaTexture(_ pose: SantaPose) -> SKTexture {
        if let cg = santaImage(pose) { return SKTexture(cgImage: cg) }
        return SKTexture()
    }

    static func santaImage(_ pose: SantaPose, scale: CGFloat = 3) -> CGImage? {
        // 44 x 52 drawing plus room for the arms to stick out.
        let r = ImageRenderer(content: Canvas { ctx, _ in
            ctx.translateBy(x: 5, y: 1)
            drawSanta(&ctx, pose: pose)
        }.frame(width: 54, height: 54))
        r.scale = scale
        return r.cgImage
    }

    /// Cute chubby Santa, drawn in a 44 x 52 box in the same brown-ink style as Pi.
    static func drawSanta(_ ctx: inout GraphicsContext, pose: SantaPose) {
        let ink = PetDrawing.ink
        let red = PetDrawing.c(0xE5493B), redDark = PetDrawing.c(0xB9302A)
        let skin = PetDrawing.c(0xFFD8BB)
        let boot = PetDrawing.c(0x3B2A1C)
        let mitten = PetDrawing.c(0x4E8A3C)
        let line = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

        // Fluffy white trim: outline every circle first, then fill them all, so only the outer edge shows.
        func fluff(_ circles: [(CGFloat, CGFloat, CGFloat)]) {
            for (x, y, r) in circles { ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(ink), lineWidth: 3) }
            for (x, y, r) in circles { ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white)) }
        }

        func arm(_ shoulder: CGPoint, angle: Double) {
            var g = ctx
            g.translateBy(x: shoulder.x, y: shoulder.y)
            g.rotate(by: .degrees(angle))
            let sleeve = Path(roundedRect: CGRect(x: -4, y: -1, width: 8, height: 12), cornerRadius: 4)
            g.fill(sleeve, with: .color(red))
            g.stroke(sleeve, with: .color(ink), style: line)
            let hand = Path(ellipseIn: CGRect(x: -4.2, y: 9.5, width: 8.4, height: 8.4))
            g.fill(hand, with: .color(mitten))
            g.stroke(hand, with: .color(ink), style: line)
            let cuff = Path(roundedRect: CGRect(x: -4.6, y: 8, width: 9.2, height: 3.2), cornerRadius: 1.6)
            g.fill(cuff, with: .color(.white))
            g.stroke(cuff, with: .color(ink), lineWidth: 1)
        }

        // boots
        for x in [11.0, 23.0] {
            let b = Path(ellipseIn: CGRect(x: x, y: 45, width: 10, height: 6.5))
            ctx.fill(b, with: .color(boot))
            ctx.stroke(b, with: .color(ink), style: line)
        }

        // arms behind the body unless they're up
        let leftAngle: Double = pose == .happy ? 150 : 28
        let rightAngle: Double = pose == .happy || pose == .wave ? -150 : -28
        if pose != .happy { arm(CGPoint(x: 10, y: 31), angle: leftAngle) }
        if pose != .happy && pose != .wave { arm(CGPoint(x: 34, y: 31), angle: rightAngle) }

        // body
        let body = Path(roundedRect: CGRect(x: 8, y: 27, width: 28, height: 22), cornerRadius: 11)
        ctx.fill(body, with: .linearGradient(Gradient(colors: [red, redDark]), startPoint: CGPoint(x: 0, y: 27), endPoint: CGPoint(x: 0, y: 49)))
        var bc = ctx
        bc.clip(to: body)
        bc.fill(Path(CGRect(x: 8, y: 39, width: 28, height: 4.2)), with: .color(boot))
        bc.fill(Path(roundedRect: CGRect(x: 10, y: 29, width: 8, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.25)))
        ctx.stroke(Path(roundedRect: CGRect(x: 19.4, y: 38.4, width: 5.2, height: 5.4), cornerRadius: 1), with: .color(PetDrawing.gold), lineWidth: 1.3)
        ctx.stroke(body, with: .color(ink), style: line)

        if pose == .happy { arm(CGPoint(x: 10, y: 31), angle: leftAngle) }
        if pose == .happy || pose == .wave { arm(CGPoint(x: 34, y: 31), angle: rightAngle) }

        // face
        let face = Path(ellipseIn: CGRect(x: 13.5, y: 11, width: 17, height: 17))
        ctx.fill(face, with: .color(skin))
        ctx.stroke(face, with: .color(ink), style: line)

        // beard
        fluff([(14.5, 22.5, 3.6), (17, 26.5, 4.2), (22, 28.2, 4.6), (27, 26.5, 4.2), (29.5, 22.5, 3.6)])

        // mustache + nose
        for x in [17.2, 21.8] {
            let m = Path(ellipseIn: CGRect(x: x, y: 21, width: 5.2, height: 3.2))
            ctx.fill(m, with: .color(.white))
            ctx.stroke(m, with: .color(ink), lineWidth: 0.9)
        }
        let nose = Path(ellipseIn: CGRect(x: 20.3, y: 18.6, width: 3.6, height: 3.3))
        ctx.fill(nose, with: .color(PetDrawing.c(0xF39484)))
        ctx.stroke(nose, with: .color(ink), lineWidth: 0.9)

        // cheeks
        for x in [13.8, 26.4] {
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: 18.4, width: 4, height: 2.4)), with: .color(PetDrawing.blush.opacity(0.85)))
        }

        // eyes
        for x in [18.2, 25.8] {
            switch pose {
            case .blink:
                var p = Path()
                p.move(to: CGPoint(x: x - 1.6, y: 16.4))
                p.addQuadCurve(to: CGPoint(x: x + 1.6, y: 16.4), control: CGPoint(x: x, y: 17.8))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            case .happy:
                var p = Path()
                p.move(to: CGPoint(x: x - 1.8, y: 17.2))
                p.addQuadCurve(to: CGPoint(x: x + 1.8, y: 17.2), control: CGPoint(x: x, y: 14.2))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            default:
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.4, y: 14.6, width: 2.8, height: 3.4)), with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: 15.0, width: 1.1, height: 1.1)), with: .color(.white))
            }
        }

        // hat
        var hat = Path()
        hat.move(to: CGPoint(x: 13, y: 12.5))
        hat.addQuadCurve(to: CGPoint(x: 32, y: 3.5), control: CGPoint(x: 17, y: 0))
        hat.addQuadCurve(to: CGPoint(x: 36.5, y: 8.5), control: CGPoint(x: 36, y: 4.5))
        hat.addQuadCurve(to: CGPoint(x: 31, y: 12.5), control: CGPoint(x: 31.5, y: 8.5))
        hat.closeSubpath()
        ctx.fill(hat, with: .linearGradient(Gradient(colors: [red, redDark]), startPoint: CGPoint(x: 14, y: 2), endPoint: CGPoint(x: 30, y: 12)))
        ctx.stroke(hat, with: .color(ink), style: line)
        fluff([(13.5, 12, 2.9), (17.3, 11.4, 3), (21.3, 11.2, 3), (25.3, 11.4, 3), (29.2, 12, 2.9)])
        fluff([(36.6, 9, 3.3)])
    }
}
