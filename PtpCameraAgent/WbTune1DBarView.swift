// WbTune1DBarView.swift
//
// 13-cell green↔magenta strip used as the NSMenuItem.view for
// 1D WB fine-tune properties (Nikon mode tunes 0xD017–0xD01D, the
// Color Temp Tune 0xD150, and the Sony per-axis tunes). Mirrors
// the HUD's `TuneBarStrip` SwiftUI implementation cell-for-cell so
// the menu and the host-app HUD look and behave identically when
// the user is tuning the same property from either surface.
//
// Click any cell to set the property to the value that cell
// represents — the cell's "value" is computed by linearly mapping
// its index 0..12 across the property's `rangeMin … rangeMax`.
// For the canonical Nikon 0..12 tunes that maps directly (each
// cell is one ±N step); for wider Sony 0..255 ranges each cell
// spans ~20 raw values (HUD-only adjustment, not a precision
// control — the user can still drop to the menu's existing
// slider submenu if they need finer steps, by changing the
// build-out below to the legacy slider).

import Cocoa

class WbTune1DBarView: NSView {
    /// Colour axis this bar visualises. Set by the caller before
    /// the view is added to the menu — `.greenMagenta` for Nikon
    /// per-mode tunes / Color Temp Tune / Sony G-M, `.amberBlue`
    /// for Sony's 0xD21C tune.
    var axis: TuneBarAxis = .greenMagenta {
        didSet { needsDisplay = true }
    }
    /// Ordered list of the discrete PTP values this property
    /// accepts. One cell per entry, in the same order as the
    /// camera advertises them (or synthesised evenly across the
    /// range if the camera only reported a range form — see
    /// `tuneStyle(forPropertyId:)`). The strip width grows with
    /// `values.count`.
    var values: [Int] = (0...12).map { $0 } {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var currentValue: Int = 6
    var onValueSelected: ((Int) -> Void)?

    private static let cellSize: CGFloat = 18
    private static let cellSpacing: CGFloat = 1

    /// Default width target — matches the HUD's preview-pane width
    /// and the Planckian-locus picker so the menu has a consistent
    /// visual rhythm. Used for the SwiftUI-equivalent default,
    /// before any caller configures `values`.
    static func idealSize(cellCount: Int = 13) -> NSSize {
        let c = max(2, cellCount)
        let w = CGFloat(c) * (cellSize + cellSpacing) + cellSpacing
        let h = cellSize + 2 * cellSpacing
        return NSSize(width: w, height: h)
    }

    override var intrinsicContentSize: NSSize {
        Self.idealSize(cellCount: values.count)
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Index ↔ value mapping

    /// Find the cell whose value is closest to the camera's current
    /// reading. Nearest-neighbour over `values` — works for both
    /// enumerated tunes (exact match) and synthesised even-spacing
    /// strips (closest representative).
    private func cellIndex(forValue value: Int) -> Int {
        guard let nearest = values.indices.min(by: {
            abs(values[$0] - value) < abs(values[$1] - value)
        }) else { return 0 }
        return nearest
    }

    private func value(forCellIndex idx: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        return values[max(0, min(values.count - 1, idx))]
    }

    private func cellAt(_ pt: CGPoint) -> Int {
        guard !values.isEmpty else { return 0 }
        let cs = Self.cellSize + Self.cellSpacing
        // Subtract the leading spacing so cell 0 starts at (cellSpacing, *).
        let idx = Int((pt.x - Self.cellSpacing) / cs)
        return max(0, min(values.count - 1, idx))
    }

    // MARK: - Drawing

    /// Cell colour for fraction `t` along the configured axis.
    /// Delegates to `TuneBarAxis.color(t:)` (in CameraModel.swift)
    /// so menu and HUD share the same gradient maths and stay in
    /// visual sync.
    private func cellColor(t: Double) -> NSColor {
        let rgb = axis.color(t: t)
        return NSColor(srgbRed: CGFloat(rgb.0),
                       green:  CGFloat(rgb.1),
                       blue:   CGFloat(rgb.2),
                       alpha:  1.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.set()
        NSBezierPath(rect: bounds).fill()

        guard !values.isEmpty else { return }
        let curIdx = cellIndex(forValue: currentValue)
        let cellCount = values.count
        for idx in 0..<cellCount {
            let t = cellCount == 1 ? 0.5 : Double(idx) / Double(cellCount - 1)
            let x = CGFloat(idx) * (Self.cellSize + Self.cellSpacing) + Self.cellSpacing
            let y = Self.cellSpacing
            let rect = CGRect(x: x, y: y, width: Self.cellSize, height: Self.cellSize)
            cellColor(t: t).set()
            NSBezierPath(rect: rect).fill()
            if idx == curIdx {
                NSColor.white.set()
                NSBezierPath(rect: rect).stroke()
            }
        }
    }

    // MARK: - Mouse handling

    /// Tracks the cell index the user pressed-down on, so we can
    /// suppress the on-mouseUp callback if they drag out and
    /// release outside the bar (which by convention means "I
    /// didn't actually mean to set anything").
    private var pressedIndex: Int? = nil

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        pressedIndex = cellAt(pt)
        // Live preview: update display immediately so the user
        // sees the highlight follow their click before release.
        currentValue = value(forCellIndex: pressedIndex!)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            let idx = cellAt(pt)
            pressedIndex = idx
            currentValue = value(forCellIndex: idx)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt), let idx = pressedIndex {
            let v = value(forCellIndex: idx)
            currentValue = v
            onValueSelected?(v)
        }
        pressedIndex = nil
        needsDisplay = true
    }
}
