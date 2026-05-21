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

    /// Debounced "post during drag" task. Replaces the in-flight
    /// item every time the user moves to a new sample so we send
    /// at most one SET ~150 ms after the user pauses — matches
    /// the slider builder's `SliderActionHolder` pattern and the
    /// host-app HUD's behaviour.
    private var dragPostTask: DispatchWorkItem? = nil
    private let dragPostDelay: TimeInterval = 0.15

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

    /// Shared geometry computed from the configured range. Lives
    /// in `CameraModel.swift`'s `PlanckianLocusGeometry` so the
    /// SwiftUI HUD picker uses the same samples and chromaticity
    /// extents as we do.
    private var geometry: PlanckianLocusGeometry =
        PlanckianLocusGeometry(rangeMin: 2500, rangeMax: 10000, step: 100)

    /// Cached chromaticity-fill bitmap. Built once per
    /// configuration via the shared `renderChromaticityFillImage`
    /// helper so the menu and HUD pickers blit bit-exactly
    /// identical pixels.
    private var cachedBackground: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        rebuildGeometry()
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
        rebuildGeometry()
        cachedBackground = nil
        needsDisplay = true
    }

    private func rebuildGeometry() {
        geometry = PlanckianLocusGeometry(
            rangeMin: rangeMin, rangeMax: rangeMax, step: step)
    }

    /// View-coord for a locus sample (proxies to the shared
    /// geometry's `viewPoint`).
    private func point(for sample: PlanckianLocusGeometry.Sample) -> CGPoint {
        geometry.viewPoint(for: sample, viewWidth: Self.viewWidth,
                           viewHeight: Self.viewHeight, inset: Self.inset)
    }

    private func closestSample(to p: CGPoint) -> PlanckianLocusGeometry.Sample? {
        geometry.closestSample(to: p, viewWidth: Self.viewWidth,
                               viewHeight: Self.viewHeight, inset: Self.inset)
    }

    private var displayedKelvin: Int { proposedKelvin ?? currentKelvin }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawChromaticityBackground()
        drawLocus()
        drawMarker()
        drawReadout()
    }

    /// Blit the cached chromaticity-fill `CGImage` produced by
    /// the shared `renderChromaticityFillImage` helper in
    /// `CameraModel.swift`. Pixel-identical with the host-app
    /// HUD's background.
    private func drawChromaticityBackground() {
        if cachedBackground == nil {
            cachedBackground = renderChromaticityFillImage(
                geometry: geometry,
                width: Int(Self.viewWidth),
                height: Int(Self.viewHeight),
                inset: Int(Self.inset))
        }
        guard let cg = cachedBackground,
              let context = NSGraphicsContext.current?.cgContext else { return }
        // The view is `isFlipped == true`, so the current
        // CGContext has its y axis flipped relative to the
        // default CG orientation. `CGContext.draw(_:in:)` blits
        // the image with its own y-up convention, which is what
        // we want — but we need to compensate the flip back so
        // the image lands the right way up.
        context.saveGState()
        context.translateBy(x: 0, y: Self.viewHeight)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0,
                                    width: Self.viewWidth,
                                    height: Self.viewHeight))
        context.restoreGState()
    }

    /// Subtle white locus stroke with shadow. Same look as the
    /// SwiftUI version — see comments in `TuneChip` / the HUD's
    /// `locusPath` for why we don't colour-stripe the curve here.
    private func drawLocus() {
        guard geometry.samples.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 1.5
        path.move(to: point(for: geometry.samples.first!))
        for s in geometry.samples.dropFirst() { path.line(to: point(for: s)) }

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
        guard let current = geometry.samples.min(by: {
            abs($0.kelvin - displayedKelvin) < abs($1.kelvin - displayedKelvin)
        }) else { return }
        let pt = point(for: current)
        let markerSize: CGFloat = 10
        let rect = CGRect(
            x: pt.x - markerSize / 2,
            y: pt.y - markerSize / 2,
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
            scheduleDragPost(kelvin: nearest.kelvin)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let nearest = closestSample(to: pt) {
            proposedKelvin = nearest.kelvin
            scheduleDragPost(kelvin: nearest.kelvin)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let nearest = closestSample(to: pt) {
            // Cancel any pending debounced post and send the
            // final value immediately on release.
            dragPostTask?.cancel()
            dragPostTask = nil
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

    private func scheduleDragPost(kelvin: Int) {
        dragPostTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.onValueSelected?(kelvin)
        }
        dragPostTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + dragPostDelay, execute: task)
    }

    // Local Sample = the shared one; helps the call sites above
    // read as "geometry.samples" rather than
    // "PlanckianLocusGeometry.Sample" repeatedly.
    typealias Sample = PlanckianLocusGeometry.Sample
}
