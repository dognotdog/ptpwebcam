// PlanckianLocusView.swift
//
// CIE-style colour-temperature picker for the agent's NSMenu. The
// NSView equivalent of the host-app HUD's `PlanckianLocusView`
// SwiftUI struct in `PreviewHud.swift` — same layout, same
// chromaticity background, same locus stroke, same drag-to-pick
// interaction. Shared underlying math (`planckianChromaticity`,
// `chromaticityRGB`) lives in `CameraModel.swift`, so the two
// surfaces stay visually identical without code duplication.
//
// Used as the `view` on an NSMenuItem (same pattern as
// `WbTuneGridView`), so it pops up as a submenu when the user
// hovers / clicks the WB Color Temperature row in the agent's
// status-bar menu.

import Cocoa

class PlanckianLocusView: NSView {
    var rangeMin: Int = 2500
    var rangeMax: Int = 10000
    var step: Int = 100
    var currentKelvin: Int = 5500
    /// Called on `mouseUp` with the user's selected CT. The agent
    /// wires this to `postPropertyCommand`, posting a SET on the
    /// per-camera command channel — same wire format as every
    /// other property change.
    var onValueSelected: ((Int) -> Void)?

    /// Live drag state — what the marker is showing while the
    /// user is dragging. Set on mouseDown/Dragged, cleared on
    /// mouseUp.
    private var proposedKelvin: Int? = nil

    private static let viewWidth: CGFloat = 220
    private static let viewHeight: CGFloat = 110
    private static let inset: CGFloat = 14

    static func idealSize() -> NSSize {
        NSSize(width: viewWidth, height: viewHeight)
    }

    // y=0 at the top, matching the HUD's SwiftUI coordinate
    // system — lets us reuse the locus coordinate math verbatim
    // without inverting for AppKit's normal y-up convention.
    override var isFlipped: Bool { true }

    private var samples: [(kelvin: Int, point: CGPoint)] = []
    private var minX: Double = 0
    private var spanX: Double = 1
    private var minY: Double = 0
    private var spanY: Double = 1

    /// Cached chromaticity-fill rendering. Computed once when the
    /// geometry / range changes; cell rendering is ~24 k fills, too
    /// slow to redo on every drag frame. The cache invalidates
    /// when `rangeMin`/`rangeMax`/`step` change via the setter
    /// (build pattern via `configure(...)` below).
    private var cachedBackground: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildSamples()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Replace the picker's configured range and current value in
    /// one shot, rebuilding the cached locus geometry and
    /// chromaticity-fill bitmap. Callers should prefer this over
    /// setting the individual properties so the cache gets
    /// invalidated coherently.
    func configure(rangeMin: Int, rangeMax: Int, step: Int, currentKelvin: Int) {
        self.rangeMin = rangeMin
        self.rangeMax = rangeMax
        self.step = step
        self.currentKelvin = currentKelvin
        buildSamples()
        cachedBackground = nil
        needsDisplay = true
    }

    // MARK: - Locus geometry

    private func buildSamples() {
        var chromPoints: [(t: Int, x: Double, y: Double)] = []
        var t = rangeMin
        while t <= rangeMax {
            let (x, y) = planckianChromaticity(kelvin: Double(t))
            chromPoints.append((t, x, y))
            t += step
        }
        guard !chromPoints.isEmpty else { return }
        // Pad the chromaticity window slightly so the locus
        // doesn't sit flush against the rendered chromaticity
        // background's edges — gives the diagram a bit of CIE
        // context (greens above the locus, magentas below).
        let pad: Double = 0.04
        minX = (chromPoints.map(\.x).min() ?? 0) - pad
        let maxX = (chromPoints.map(\.x).max() ?? 0) + pad
        minY = (chromPoints.map(\.y).min() ?? 0) - pad
        let maxY = (chromPoints.map(\.y).max() ?? 0) + pad
        spanX = max(0.0001, maxX - minX)
        spanY = max(0.0001, maxY - minY)
        samples = chromPoints.map { sample in
            let nx = (sample.x - minX) / spanX
            let ny = 1.0 - (sample.y - minY) / spanY
            let px = Self.inset + CGFloat(nx) * (Self.viewWidth - 2 * Self.inset)
            let py = Self.inset + CGFloat(ny) * (Self.viewHeight - 2 * Self.inset)
            return (sample.t, CGPoint(x: px, y: py))
        }
    }

    private func closestSample(to p: CGPoint) -> (kelvin: Int, point: CGPoint)? {
        var best: (kelvin: Int, point: CGPoint)?
        var bestDist = CGFloat.infinity
        for s in samples {
            let dx = s.point.x - p.x
            let dy = s.point.y - p.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = s }
        }
        return best
    }

    private var displayedKelvin: Int { proposedKelvin ?? currentKelvin }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawChromaticityBackground()
        drawLocus()
        drawMarker()
        drawReadout()
    }

    /// Renders the (x, y) chromaticity field to an NSImage and
    /// caches it. Calling `draw(...)` then just blits the cached
    /// bitmap. ~24 k 1-pt fills the first time; near-free thereafter.
    private func drawChromaticityBackground() {
        if cachedBackground == nil {
            let size = NSSize(width: Self.viewWidth, height: Self.viewHeight)
            let image = NSImage(size: size)
            image.lockFocus()
            // The locked focus uses the image's coordinate space
            // (y-up by default for NSImage). Render with our usual
            // y-down logic by flipping at the end of each row.
            let cellSize: CGFloat = 1
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for col in 0..<cols {
                let cellX = CGFloat(col) * cellSize
                let nx = Double((cellX + cellSize / 2 - Self.inset) /
                                max(1, Self.viewWidth - 2 * Self.inset))
                let chromX = minX + max(0, min(1, nx)) * spanX
                for row in 0..<rows {
                    let cellY = CGFloat(row) * cellSize
                    // Convert to y-down "ny" since the locus map
                    // assumes top=0.
                    let nyTopDown = Double(
                        (Self.viewHeight - cellY - cellSize / 2 - Self.inset) /
                        max(1, Self.viewHeight - 2 * Self.inset))
                    let chromY = minY + (1.0 - max(0, min(1, nyTopDown))) * spanY
                    let rgb = chromaticityRGB(x: chromX, y: chromY)
                    NSColor(srgbRed: CGFloat(rgb.0),
                            green:  CGFloat(rgb.1),
                            blue:   CGFloat(rgb.2),
                            alpha: 1.0).set()
                    NSBezierPath(rect: CGRect(x: cellX, y: cellY,
                                              width: cellSize, height: cellSize)).fill()
                }
            }
            image.unlockFocus()
            cachedBackground = image
        }
        cachedBackground?.draw(in: bounds)
    }

    /// Subtle white locus stroke with shadow. Same look as the
    /// SwiftUI version — see comments in `TuneChip` / the HUD's
    /// `locusPath` for why we don't colour-stripe the curve here.
    private func drawLocus() {
        guard samples.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 1.5
        path.move(to: samples.first!.point)
        for s in samples.dropFirst() { path.line(to: s.point) }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMarker() {
        guard let current = samples.min(by: {
            abs($0.kelvin - displayedKelvin) < abs($1.kelvin - displayedKelvin)
        }) else { return }
        let markerSize: CGFloat = 10
        let rect = CGRect(
            x: current.point.x - markerSize / 2,
            y: current.point.y - markerSize / 2,
            width: markerSize, height: markerSize)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 2
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let stroke = NSBezierPath(ovalIn: rect)
        stroke.lineWidth = 1
        stroke.stroke()
    }

    /// "5500K" pill rendered at the top of the view, matching
    /// the HUD's collapsed-chip label position.
    private func drawReadout() {
        let text = "\(displayedKelvin)K" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let padX: CGFloat = 6
        let padY: CGFloat = 2
        let pillW = textSize.width + 2 * padX
        let pillH = textSize.height + 2 * padY
        let pillRect = CGRect(
            x: (Self.viewWidth - pillW) / 2,
            y: 4,
            width: pillW, height: pillH)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pillRect,
                     xRadius: pillH / 2, yRadius: pillH / 2).fill()
        text.draw(at: NSPoint(x: pillRect.origin.x + padX,
                              y: pillRect.origin.y + padY),
                  withAttributes: attrs)
    }

    // MARK: - Mouse handling

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let nearest = closestSample(to: pt) {
            proposedKelvin = nearest.kelvin
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let nearest = closestSample(to: pt) {
            proposedKelvin = nearest.kelvin
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let nearest = closestSample(to: pt) {
            // Optimistic update: the camera value will round-trip
            // back through `processPropertyStateJson` over the next
            // publish, but the menu may still be visible until
            // then and the user expects the marker to stay where
            // they dropped it.
            currentKelvin = nearest.kelvin
            onValueSelected?(nearest.kelvin)
        }
        proposedKelvin = nil
        needsDisplay = true
    }
}
