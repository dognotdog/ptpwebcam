import Cocoa

// 13×13 WB fine-tune matrix, ported from PtpGridTuneView (ObjC DAL plugin).
// Embeds in an NSMenuItem.view. Click/drag selects a cell; mouseUp fires onValueSelected.
class WbTuneGridView: NSView {
    var gridSize: Int = 13
    var currentValue: Int = 0
    var rangeMin: Int = 0
    var rangeMax: Int = 168
    var onValueSelected: ((Int) -> Void)?

    private static let cellSize: CGFloat = 16
    private var highlightedX: Int = -1
    private var highlightedY: Int = -1  // draw-loop y: 0 = visually top row
    private var trackingArea: NSTrackingArea?

    static func idealSize(gridSize: Int) -> NSSize {
        let s = CGFloat(gridSize) * (cellSize + 1) + 1
        return NSSize(width: s, height: s)
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // Convert draw-loop (x, y) — y=0 is top — to encoded PTP value.
    // Delegates to the shared `encodeWbTuneGrid` helper in
    // `CameraModel.swift` so the agent menu and the host-app HUD
    // matrix picker stay in lockstep on the encoding.
    private func valueFrom(x: Int, y: Int) -> Int {
        encodeWbTuneGrid(x: x, y: y, rangeMax: rangeMax)
    }

    // Convert AppKit point (y=0 at bottom) to draw-loop cell (y=0 at top).
    private func cellAt(_ pt: CGPoint) -> (x: Int, y: Int) {
        let cs = WbTuneGridView.cellSize + 1
        let sx = max(0, min(gridSize - 1, Int((pt.x - 1) / cs)))
        let sy = max(0, min(gridSize - 1, Int((pt.y - 1) / cs)))  // 0 = bottom
        return (x: sx, y: gridSize - sy - 1)                      // flip to draw-loop
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.set()
        NSBezierPath(rect: bounds).fill()

        let cs = WbTuneGridView.cellSize
        for dlY in 0..<gridSize {
            let pixY = CGFloat(gridSize - dlY - 1) * (cs + 1) + 1  // flip back to pixel
            for x in 0..<gridSize {
                let rect = CGRect(x: CGFloat(x) * (cs + 1) + 1, y: pixY, width: cs, height: cs)
                let val  = valueFrom(x: x, y: dlY)

                if val == currentValue {
                    NSColor.white.set()
                } else {
                    colorFor(xt: CGFloat(x) / CGFloat(gridSize),
                             yt: CGFloat(dlY) / CGFloat(gridSize)).set()
                }
                NSBezierPath(rect: rect).fill()

                if x == highlightedX && dlY == highlightedY {
                    NSColor.white.set()
                    NSBezierPath(rect: rect).stroke()
                }
            }
        }
    }

    // Bilinear blend of four corner colours. Endpoints picked as
    // true RGB complements (blue ↔ yellow, green ↔ magenta) so the
    // matrix centre — "no fine-tune offset" — is exact neutral
    // gray (0.5, 0.5, 0.5).
    //
    // Corner colours after the per-axis 50/50 blend:
    //   TL (xt=0, yt=0): blue+green   = (0.0, 0.5, 0.5)
    //   TR (xt=1, yt=0): yellow+green = (0.5, 1.0, 0.0)
    //   BL (xt=0, yt=1): blue+magenta = (0.5, 0.0, 1.0)
    //   BR (xt=1, yt=1): yellow+magenta = (1.0, 0.5, 0.5)
    //   centre = average = (0.5, 0.5, 0.5) ✓
    //
    // Direct sRGB linear interpolation rather than
    // `NSColor.blended(withFraction:of:)`. `blended` works in the
    // source colour's colourspace and applies a gamma-corrected
    // mix; for the nominal-50% blend of e.g. NSColor.green and
    // NSColor.magenta that produces a not-quite-neutral grey at
    // the centre once it gets rendered. Doing the interp here on
    // raw sRGB components and constructing the result via
    // `NSColor(srgbRed:green:blue:)` keeps the centre cell
    // perceptually neutral and bit-exactly matches the host-app
    // HUD's `matrixColor` in `PreviewHud.swift`.
    private func colorFor(xt: CGFloat, yt: CGFloat) -> NSColor {
        let tl: (CGFloat, CGFloat, CGFloat) = (0.0, 0.5, 0.5)
        let tr: (CGFloat, CGFloat, CGFloat) = (0.5, 1.0, 0.0)
        let bl: (CGFloat, CGFloat, CGFloat) = (0.5, 0.0, 1.0)
        let br: (CGFloat, CGFloat, CGFloat) = (1.0, 0.5, 0.5)
        let top = lerp(tl, tr, t: xt)
        let bot = lerp(bl, br, t: xt)
        let mid = lerp(top, bot, t: yt)
        return NSColor(srgbRed: mid.0, green: mid.1, blue: mid.2, alpha: 1)
    }

    private func lerp(_ a: (CGFloat, CGFloat, CGFloat),
                      _ b: (CGFloat, CGFloat, CGFloat),
                      t: CGFloat)
        -> (CGFloat, CGFloat, CGFloat) {
        (a.0 + (b.0 - a.0) * t,
         a.1 + (b.1 - a.1) * t,
         a.2 + (b.2 - a.2) * t)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let c = cellAt(convert(event.locationInWindow, from: nil))
        highlightedX = c.x; highlightedY = c.y
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            let c = cellAt(pt); highlightedX = c.x; highlightedY = c.y
        } else {
            highlightedX = -1; highlightedY = -1
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            let c = cellAt(pt)
            currentValue = valueFrom(x: c.x, y: c.y)
            onValueSelected?(currentValue)
        }
        highlightedX = -1; highlightedY = -1
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent)  { highlightedX = -1; highlightedY = -1; needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return }
        trackingArea = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .enabledDuringMouseDrag, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
}
