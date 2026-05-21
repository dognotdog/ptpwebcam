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
    var rangeMin: Int = 0
    var rangeMax: Int = 12
    var currentValue: Int = 6
    var onValueSelected: ((Int) -> Void)?

    private static let cellCount: Int = 13
    private static let cellSize: CGFloat = 18
    private static let cellSpacing: CGFloat = 1

    static func idealSize() -> NSSize {
        let w = CGFloat(cellCount) * (cellSize + cellSpacing) + cellSpacing
        let h = cellSize + 2 * cellSpacing
        return NSSize(width: w, height: h)
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Index ↔ value mapping

    private func cellIndex(forValue value: Int) -> Int {
        let span = max(1, rangeMax - rangeMin)
        let normalized = Double(value - rangeMin) / Double(span)
        let raw = Int(round(normalized * Double(Self.cellCount - 1)))
        return max(0, min(Self.cellCount - 1, raw))
    }

    private func value(forCellIndex idx: Int) -> Int {
        let normalized = Double(idx) / Double(Self.cellCount - 1)
        return rangeMin + Int(round(normalized * Double(rangeMax - rangeMin)))
    }

    private func cellAt(_ pt: CGPoint) -> Int {
        let cs = Self.cellSize + Self.cellSpacing
        // Subtract the leading spacing so cell 0 starts at (cellSpacing, *).
        let idx = Int((pt.x - Self.cellSpacing) / cs)
        return max(0, min(Self.cellCount - 1, idx))
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

        let curIdx = cellIndex(forValue: currentValue)
        for idx in 0..<Self.cellCount {
            let t = Double(idx) / Double(Self.cellCount - 1)
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
