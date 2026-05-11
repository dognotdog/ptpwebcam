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
    private func valueFrom(x: Int, y: Int) -> Int {
        if rangeMin == 0 && rangeMax == 168  && gridSize == 13 { return x + y * gridSize }
        if rangeMin == 0 && rangeMax == 1224 && gridSize == 13 { return x * 2 + y * 100 }
        return 0
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

    private func colorFor(xt: CGFloat, yt: CGFloat) -> NSColor {
        let xy = NSColor.blue.blended(withFraction: 0.5, of: .green)!
        let xY = NSColor.blue.blended(withFraction: 0.5, of: .magenta)!
        let Xy = NSColor.orange.blended(withFraction: 0.5, of: .green)!
        let XY = NSColor.orange.blended(withFraction: 0.5, of: .magenta)!
        let xc = xy.blended(withFraction: xt, of: Xy)!
        let Xc = xY.blended(withFraction: xt, of: XY)!
        return xc.blended(withFraction: yt, of: Xc)!
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
