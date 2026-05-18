import AppKit
import QuartzCore

// MARK: - Confetti Emitter View (CAEmitterLayer-based)

class ConfettiEmitterView: NSView {
    private var emitters: [CAEmitterLayer] = []

    private static let confettiColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.22, blue: 0.35, alpha: 1),  // hot pink
        NSColor(red: 1.0, green: 0.55, blue: 0.0,  alpha: 1),  // orange
        NSColor(red: 1.0, green: 0.84, blue: 0.0,  alpha: 1),  // gold
        NSColor(red: 0.3, green: 0.85, blue: 0.4,  alpha: 1),  // green
        NSColor(red: 0.2, green: 0.6,  blue: 1.0,  alpha: 1),  // blue
        NSColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1),  // purple
        NSColor(red: 0.95, green: 0.3, blue: 0.7,  alpha: 1),  // magenta
        NSColor(red: 0.0, green: 0.9,  blue: 0.85, alpha: 1),  // cyan
        NSColor(red: 1.0, green: 0.95, blue: 0.4,  alpha: 1),  // light gold
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Burst confetti from a point in CA coordinates (bottom-left origin).
    /// When `shootingDown` is true (e.g. from menu bar), particles spray downward.
    func startConfetti(from origin: CGPoint, shootingDown: Bool = false) {
        let shapes: [CGImage] = [
            makeRect(width: 8, height: 5),      // wide rectangle
            makeRect(width: 3, height: 10),     // tall strip
            makeCircle(diameter: 5),             // dot
            makeRect(width: 7, height: 7),      // square
            makeRect(width: 4, height: 9),      // medium strip
            makeRect(width: 9, height: 3),      // wide banner
        ]

        let emitter = CAEmitterLayer()
        emitter.emitterPosition = origin
        emitter.emitterSize = CGSize(width: 6, height: 6)
        emitter.emitterShape = .point
        emitter.renderMode = .oldestLast
        emitter.seed = UInt32.random(in: 0...UInt32.max)

        var cells: [CAEmitterCell] = []
        for color in Self.confettiColors {
            let cell = CAEmitterCell()
            cell.contents = shapes.randomElement()!
            cell.birthRate = 500             // 10 colors × 500 × 0.18s ≈ 900 particles
            cell.lifetime = 5.5
            cell.lifetimeRange = 1.5
            if shootingDown {
                cell.velocity = 400
                cell.velocityRange = 250
                cell.emissionLongitude = -.pi / 2 // downward in CA coords
                cell.emissionRange = .pi * 0.5    // 90° each side = wide shower
                cell.yAcceleration = -200         // gentle gravity assists the fall
            } else {
                cell.velocity = 800
                cell.velocityRange = 300
                cell.emissionLongitude = .pi / 2  // upward in CA coords
                cell.emissionRange = .pi * 0.4    // 72° each side = 145° spread
                cell.yAcceleration = -420         // gravity — parabolic arc
            }
            cell.xAcceleration = 0
            cell.spin = 3.5
            cell.spinRange = 6.0
            cell.scale = 0.8
            cell.scaleRange = 0.3
            cell.scaleSpeed = -0.04          // slight shrink over life
            cell.alphaSpeed = -0.12          // gradual fade
            cell.color = color.cgColor
            cells.append(cell)
        }

        emitter.emitterCells = cells
        emitter.beginTime = CACurrentMediaTime()
        layer?.addSublayer(emitter)
        emitters.append(emitter)

        // Short burst then stop — already-emitted particles continue their arc
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            emitter.birthRate = 0
        }
    }

    // MARK: - Shape Images (white base, tinted by cell.color)

    private func makeRect(width: CGFloat, height: CGFloat) -> CGImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func makeCircle(diameter: CGFloat) -> CGImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}

// MARK: - Full-Screen Confetti Window Controller

class ConfettiWindowController {
    /// One panel per physical screen — avoids macOS constraining cross-screen windows.
    private var panels: [CGDirectDisplayID: (panel: NSPanel, emitterView: ConfettiEmitterView)] = [:]
    private var dismissTimer: DispatchWorkItem?
    private let displayDuration: TimeInterval = 6.0

    /// Show confetti bursting from a screen coordinate.
    /// Can be called multiple times — bursts stack on the same screen's panel.
    /// Set `shootingDown` for menu bar origins so particles spray downward.
    func showConfetti(from screenPoint: CGPoint? = nil, shootingDown: Bool = false) {
        // Find the screen containing the origin point
        let targetScreen: NSScreen
        if let sp = screenPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(sp) }) {
            targetScreen = screen
        } else {
            guard let main = NSScreen.main else {
                TBLog.log("showConfetti: no screens!", category: "confetti")
                return
            }
            targetScreen = main
        }

        let screenID = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
        let frame = targetScreen.frame

        // Get or create panel for this screen
        let entry: (panel: NSPanel, emitterView: ConfettiEmitterView)
        if let existing = panels[screenID] {
            entry = existing
        } else {
            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

            let ev = ConfettiEmitterView(frame: NSRect(origin: .zero, size: frame.size))
            ev.autoresizingMask = [.width, .height]
            p.contentView = ev
            p.orderFrontRegardless()

            entry = (panel: p, emitterView: ev)
            panels[screenID] = entry
        }

        // Convert screen coordinates to panel-local (both use bottom-left origin)
        let localPoint: CGPoint
        if let sp = screenPoint {
            localPoint = CGPoint(x: sp.x - frame.origin.x, y: sp.y - frame.origin.y)
        } else {
            localPoint = CGPoint(x: frame.width / 2, y: frame.height * 0.5)
        }

        entry.emitterView.startConfetti(from: localPoint, shootingDown: shootingDown)
        TBLog.log("showConfetti: screen=\(targetScreen.localizedName) localPt=(\(Int(localPoint.x)),\(Int(localPoint.y))) down=\(shootingDown)", category: "confetti")

        // Reset the dismiss timer — all panels stay open until last burst settles
        dismissTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: work)
    }

    func dismiss() {
        for (_, entry) in panels {
            entry.panel.orderOut(nil)
        }
        panels.removeAll()
        dismissTimer = nil
    }
}
