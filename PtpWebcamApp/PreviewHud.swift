// PreviewHud.swift
//
// Interactive HUD overlay drawn on top of the camera preview window.
// Each "chip" is a translucent pill with a static role label on the
// left (e.g. "ISO") and a value wheel on the right.
//
// Selector-wheel animation: while a chip is expanded, all enum values
// for that property are rendered at fixed slot positions inside a
// 3-slot-wide clipped viewport. Each value sits at an offset of
// `(itsIndex − currentIndex) * slotWidth`. When the current index
// changes — whether the user tapped prev/next, used the camera dial,
// or changed the value from the agent menu — every value's offset
// updates by one slot width, and SwiftUI animates the entire strip
// sliding left or right. No matched-geometry shenanigans, no
// fade-in/out of entering and exiting values — everything just
// slides as a single ribbon. Values past ±1 slots from centre fade
// out via opacity so the wheel appears to fit cleanly inside the
// pill.
//
// Geometry constraint (centre stays under cursor): in a centred
// HStack of chips, when one chip's width grows by ΔW, the row's
// total grows by ΔW, the row's centred position shifts by ΔW/2, and
// the chip's offset within the row grows by ΔW/2 — the two cancel
// exactly. The expansion can be asymmetric (different left/right
// slot widths, different prev-vs-next slot counts, etc.) and the
// chip's absolute centre still stays fixed.

import SwiftUI

// MARK: - Layout model

/// Defaults follow DSLR-viewfinder reading order:
///   • Top centre: color-related (white balance).
///   • Bottom centre: exposure-related (shutter, aperture, ISO, EV, M).
struct HudLayout {
    var top: [SemanticCameraProperty]
    var bottom: [SemanticCameraProperty]

    static let `default` = HudLayout(
        top: [.autofocusTrigger, .autofocusMode, .whiteBalance],
        bottom: [.shutterSpeed, .aperture, .iso, .exposureCompensation, .exposureMode]
    )
}

// MARK: - View

struct PreviewHud: View {
    let camera: ExtCamera?
    let layout: HudLayout
    let visible: Bool

    /// PTP id of the chip currently expanded into the inline value
    /// wheel. `nil` = all chips collapsed. At most one chip can be
    /// expanded at a time; tapping another collapses the previous.
    /// Reset to nil whenever `visible` flips to false so the HUD
    /// comes back in a clean state next time.
    ///
    /// Identified by PTP property id rather than `SemanticCameraProperty`
    /// because the WB role spawns additional tune chips (whose ids
    /// vary by mode — Daylight Tune 0xD01A, Color Temp Tune 0xD150,
    /// Sony G-M 0xD210, etc.) that don't map to the semantic enum.
    @State private var expandedPropId: UInt32? = nil

    var body: some View {
        GeometryReader { _ in
            // The transparent background must NOT swallow mouse events
            // or empty-area clicks inside the preview would never reach
            // PreviewView.mouseDown for the HUD-visibility toggle. The
            // overlay-rendered chip pills are siblings, not children,
            // of this disabled-hit-test layer, so they remain tappable.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .top)    { chipGroup(for: layout.top) }
                .overlay(alignment: .bottom) { chipGroup(for: layout.bottom) }
                .padding(12)
        }
        .opacity(visible ? 1 : 0)
        // Collapse any expanded chip whenever the HUD fades out so the
        // next show starts clean. Single-parameter `onChange` overload
        // keeps us compatible with macOS 13.5 (current deployment).
        .onChange(of: visible) { newValue in
            if !newValue { expandedPropId = nil }
        }
        .animation(.easeInOut(duration: 0.18), value: visible)
    }

    /// One row of chips for the given roles. The chips that get
    /// rendered: one per semantic role that the camera supports,
    /// plus — for the white-balance role only — any per-mode tune
    /// sub-property chips returned by
    /// `whiteBalanceTunePropertyIds()`. So a Nikon body set to
    /// Daylight WB gets a [WB][Tune] pair in the top group; set to
    /// Color Temperature it gets [WB(Kelvin)][Tune]; Auto mode adds
    /// both the Auto Tune and Auto Type chips.
    @ViewBuilder
    private func chipGroup(for roles: [SemanticCameraProperty]) -> some View {
        if let cam = camera {
            let plan = chipPlan(for: roles, camera: cam)
            if !plan.isEmpty {
                // Top-align the row's children so when one chip
                // expands into a tall 2D matrix it grows DOWN from
                // its original position rather than centring the
                // whole row vertically around the matrix (which
                // would push every neighbour chip half its height
                // upward).
                HStack(alignment: .top, spacing: 6) {
                    ForEach(plan) { item in
                        switch item.kind {
                        case .autofocusTrigger:
                            AutofocusTriggerChip(camera: cam)
                        case .property(let propId):
                            if let prop = cam.properties[propId] {
                                // Tune properties (the WB
                                // fine-tune matrices and 1D ±N
                                // bars) get a colour-cell
                                // visualisation rather than the
                                // numeric wheel — the raw PTP
                                // integer encodes a position on a
                                // colour grid and means nothing
                                // to the user as a number.
                                if cam.isColorTemperatureProperty(propId) {
                                    // Kelvin values: stylised
                                    // CIE-locus picker. Lets the
                                    // user drag a marker along
                                    // the Planckian curve to pick
                                    // a CT, rather than stepping
                                    // discrete values one at a
                                    // time.
                                    ColorTemperatureChip(label: item.label,
                                                         camera: cam,
                                                         propId: propId,
                                                         prop: prop,
                                                         expandedPropId: $expandedPropId)
                                } else if let style = cam.tuneStyle(forPropertyId: propId) {
                                    TuneChip(label: item.label,
                                             camera: cam,
                                             propId: propId,
                                             prop: prop,
                                             style: style,
                                             expandedPropId: $expandedPropId)
                                } else {
                                    ChipPill(label: item.label,
                                             camera: cam,
                                             propId: propId,
                                             prop: prop,
                                             expandedPropId: $expandedPropId)
                                }
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: expandedPropId)
                // Re-animate when WB mode changes — tune chips
                // appear/disappear and the row needs to slide its
                // chips to accommodate. Without this trigger, the
                // tune-chip swap on a WB mode change would pop in
                // instead of sliding.
                .animation(.easeInOut(duration: 0.22),
                           value: cam.property(for: .whiteBalance)?.value.uint32Value)
            }
        }
    }

    /// Description of one chip slot in the rendered row. Most
    /// items represent a PTP property (id + label); the AF trigger
    /// is a virtual non-property action so it gets its own kind.
    /// Distinguished via `Kind` rather than a magic propId because
    /// the dispatch is type-safe and the trigger doesn't carry an
    /// `ExtCameraProperty` SwiftUI can route on.
    private struct ChipPlanItem: Identifiable {
        enum Kind: Equatable {
            case property(UInt32)
            case autofocusTrigger
        }
        let kind: Kind
        let label: String
        var id: String {
            switch kind {
            case .property(let propId): return "p-\(propId)"
            case .autofocusTrigger:     return "af-trigger"
            }
        }
    }

    /// Build the ordered list of chips to render for a row, walking
    /// the requested semantic roles and inserting any white-balance
    /// tune chips immediately after the WB chip itself.
    private func chipPlan(for roles: [SemanticCameraProperty],
                          camera: ExtCamera) -> [ChipPlanItem] {
        var items: [ChipPlanItem] = []
        for role in roles {
            switch role {
            case .autofocusTrigger:
                // Virtual role — render only if the extension
                // actually supports the trigger command on this
                // vendor / body.
                if camera.supportsAutofocusTrigger {
                    items.append(ChipPlanItem(kind: .autofocusTrigger,
                                              label: role.displayName))
                }
            default:
                guard let propId = camera.propertyId(for: role) else { continue }
                items.append(ChipPlanItem(kind: .property(propId),
                                          label: role.displayName))
                // After the WB chip, append the relevant tune
                // controls for the currently-selected WB mode (or
                // the Sony G-M / A-B tunes regardless of mode).
                if role == .whiteBalance {
                    for tuneId in camera.whiteBalanceTunePropertyIds() {
                        items.append(ChipPlanItem(kind: .property(tuneId),
                                                  label: whiteBalanceTuneLabel(for: tuneId)))
                    }
                }
            }
        }
        return items
    }

    /// Short label for the tune chips. WB tune properties have
    /// long official names ("WB Fluorescent Tune") that would
    /// dominate the chip — the WB chip next to them already tells
    /// the user which mode the tune belongs to, so we use compact
    /// generic labels here.
    private func whiteBalanceTuneLabel(for propId: UInt32) -> String {
        switch propId {
        case 0xD01E, 0xD20F:       // WB Color Temperature (Kelvin reading)
            return "CT"
        case 0xD141, 0xD14F:       // WB Auto Type / Fluorescent Type
            return "Type"
        case 0xD210:               // Sony G-M tune
            return "GM"
        case 0xD21C:               // Sony A-B tune
            return "AB"
        default:                   // every per-mode Nikon tune ID
            return "Tune"
        }
    }
}

// MARK: - ChipPill

private struct ChipPill: View {
    /// Short label drawn in the static left-hand region of the
    /// chip (e.g. "ISO", "WB", "Tune"). For the semantic chips
    /// this comes from `SemanticCameraProperty.displayName`; for
    /// the WB tune sub-property chips it comes from the layout-
    /// side `whiteBalanceTuneLabel(for:)`. Stored as a string so
    /// `ChipPill` doesn't have to know about either source.
    let label: String
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    /// The PreviewHud-wide "which chip is open" state. Each pill
    /// matches against its own `propId`; tapping to expand sets it,
    /// tapping again or hovering out clears it.
    @Binding var expandedPropId: UInt32?

    /// Pending collapse-on-cursor-leave task, kept on the view so a
    /// rapid hover-out/hover-in (which happens when the cursor brushes
    /// the chip's edge while the user is actually trying to land on
    /// a side slot) cancels the collapse before it fires. See the
    /// `.onHover` handler at the bottom of `body`.
    @State private var pendingCollapse: DispatchWorkItem?

    /// Visible slot count for the expanded wheel viewport. Three is
    /// the natural "prev / current / next" reading; the strip itself
    /// renders ALL enum values but only this many slot-widths of it
    /// peek through the clip mask. Values past ±1 from centre fade
    /// to opacity 0 so they don't crowd the visible window.
    private let visibleSlots: Int = 3

    /// Vertical content height the chip uses. Picked to match the
    /// natural height of the callout-bold-monospaced text so we don't
    /// add extra vertical breathing room beyond what the text needs.
    private let chipHeight: CGFloat = 18

    /// Grace window before a hover-out triggers collapse. Short
    /// enough to feel responsive, long enough that a momentary
    /// flicker (cursor brushing the rounded corner of the pill, or
    /// crossing the gap between the chip and the side slot that
    /// just shifted into view) doesn't dismiss the expansion the
    /// user is mid-interaction with.
    private let hoverOutCollapseDelay: TimeInterval = 0.15

    var body: some View {
        let isExpanded = (expandedPropId == propId)
        let interactive = prop.writable
            && prop.enumValues != nil
            && !(prop.enumValues!.isEmpty)

        HStack(spacing: 3) {
            labelSegment(isExpanded: isExpanded, interactive: interactive)
            // The wheel renders at every render — collapsed just
            // narrows its viewport to a single slot. Doing it this
            // way keeps the label segment's identity stable across
            // expansion (no view tree restructuring → no glitch in
            // the label's position or material rendering).
            valueWheel(isExpanded: isExpanded, interactive: interactive)
        }
        // Disable hit-testing on the inner content while collapsed.
        // SwiftUI Buttons (even .buttonStyle(.plain) ones) flash a
        // brief press-state visual when clicked, which the user
        // sees as a "label glitch" or "value glitch" when really
        // they want the whole chip to expand without any inner
        // press feedback. Falling clicks through to the chip's
        // outer `.onTapGesture` below makes the chip behave like
        // one big button until it's expanded — only then do the
        // individual wheel slots / label-to-collapse become live.
        .allowsHitTesting(isExpanded)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        // The entire pill is a tap target. Without this, clicks on
        // the HStack's inter-child spacing (between the label and
        // the wheel) had no inner Button to absorb them and fell
        // through to PreviewView's mouseDown — surprising, since
        // the chip looks like one continuous control. Inner
        // Buttons (label, wheel slots) still take priority because
        // SwiftUI matches inner gestures first; this gesture only
        // fires on the gap / pill background.
        .contentShape(Capsule())
        .onTapGesture {
            guard interactive else { return }
            if expandedPropId != propId {
                expandedPropId = propId
            }
        }
        // The pill animates its overall width when transitioning
        // between collapsed and expanded.
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        // Collapse-on-hover-leave: when the cursor moves off the
        // pill we schedule a collapse after `hoverOutCollapseDelay`.
        // If the cursor returns within that window, we cancel.
        // Result: the user can fly the cursor between chips and the
        // previously-expanded chip closes on its own, without
        // needing a click-to-dismiss interaction.
        .onHover { hovering in
            pendingCollapse?.cancel()
            pendingCollapse = nil
            if hovering { return }
            guard expandedPropId == propId else { return }
            let task = DispatchWorkItem {
                // Re-check on fire — a fresh hover-in could have
                // arrived before the timer ran on the main queue.
                if expandedPropId == propId {
                    expandedPropId = nil
                }
            }
            pendingCollapse = task
            DispatchQueue.main.asyncAfter(
                deadline: .now() + hoverOutCollapseDelay,
                execute: task)
        }
    }

    // MARK: Label

    /// Static role label segment (e.g. "ISO"). Anchors the chip's
    /// identity while the values slide past it during wheel
    /// rotation. Uses `.primary` + manual opacity rather than
    /// `.secondary` so its appearance is decoupled from the
    /// SwiftUI hierarchy that the wheel slots also use — keeps
    /// the label's rendering stable when the wheel's own opacity
    /// modifiers are animating around it.
    private func labelSegment(isExpanded: Bool, interactive: Bool) -> some View {
        // Wrap the label in a plain Button so a click anywhere on
        // the label area expands the chip (when collapsed) or
        // collapses it (when expanded), matching the centre-slot
        // tap behaviour. Without this the only interactive region
        // when collapsed was the current value text inside the
        // wheel — clicking the label was a dead spot.
        Button {
            guard interactive else { return }
            expandedPropId = isExpanded ? nil : propId
        } label: {
            Text(label)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.primary)
                .opacity(0.6)
                // `.fixedSize(horizontal:)` keeps the label at its
                // intrinsic width even when the chip group HStack
                // is squeezed (which would otherwise truncate the
                // label to an ellipsis, since the wheel has an
                // explicit `.frame(width:)` and SwiftUI compresses
                // unconstrained siblings first).
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
    }

    // MARK: Wheel

    /// The selector-wheel viewport. Renders all enum values at fixed
    /// offsets relative to the current value's index; when current
    /// changes, every value's offset shifts by the same slot width,
    /// producing the unified-strip slide. Same structure whether the
    /// chip is collapsed (viewport width = 1 slot, only centre shown)
    /// or expanded (viewport width = 3 slots, prev/centre/next shown).
    @ViewBuilder
    private func valueWheel(isExpanded: Bool, interactive: Bool) -> some View {
        // Fallback to a single-element list if the property has no
        // enum (range/incremental) — collapsed display still works,
        // expansion is gated by `interactive` so we never try to
        // step through a non-enum property.
        let allValues = prop.enumValues ?? [prop.value]
        let currentIdx = allValues.firstIndex { $0.uint32Value == prop.value.uint32Value } ?? 0
        let slotWidth = computeSlotWidth(for: allValues)
        let visible = isExpanded ? visibleSlots : 1
        ZStack {
            ForEach(allValues.indices, id: \.self) { idx in
                wheelSlot(idx: idx,
                          allValues: allValues,
                          currentIdx: currentIdx,
                          slotWidth: slotWidth,
                          isExpanded: isExpanded,
                          interactive: interactive)
            }
        }
        .frame(width: slotWidth * CGFloat(visible), height: chipHeight)
        .clipped()
        // Driver: when the current index moves, every slot's offset
        // and opacity (computed in `wheelSlot`) gets a new value,
        // and SwiftUI animates those transitions in lockstep — the
        // entire wheel slides as a single ribbon.
        .animation(.easeInOut(duration: 0.22), value: currentIdx)
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    /// One slot of the wheel. Every slot uses the SAME font, weight,
    /// and foreground colour — only `.opacity` differs between the
    /// centre and side slots, because opacity is the only one of
    /// those three properties SwiftUI knows how to interpolate. Font
    /// weight and `.foregroundStyle(.primary/.secondary)` don't
    /// animate, so swapping them on every wheel rotation was what
    /// produced the abrupt contrast jump the user reported.
    private func wheelSlot(idx: Int,
                           allValues: [NSNumber],
                           currentIdx: Int,
                           slotWidth: CGFloat,
                           isExpanded: Bool,
                           interactive: Bool) -> some View {
        let value = allValues[idx]
        let dx = idx - currentIdx
        let absDx = abs(dx)
        let valueStr = formatExtPropRaw(value, propId: propId, vendor: camera.vendor)
        // Opacity falls off with distance from centre. When the chip
        // is collapsed only the centre slot is visible (everything
        // else is opacity 0); when expanded the immediate
        // neighbours show at 0.55, slots further out at 0.
        let opacity: Double
        if !isExpanded {
            opacity = (absDx == 0) ? 1.0 : 0.0
        } else {
            switch absDx {
            case 0: opacity = 1.0
            case 1: opacity = 0.55
            default: opacity = 0.0
            }
        }
        return Button {
            if absDx == 0 {
                // Centre tap toggles expansion. When collapsed it
                // expands; when expanded it collapses. Replaces what
                // used to be a separate `.onTapGesture` on the
                // outer pill — keeping the toggle inside the wheel
                // means the hit area exactly matches the centre slot
                // (so a click on the label OR the side slots doesn't
                // accidentally toggle).
                guard interactive else { return }
                expandedPropId = isExpanded ? nil : propId
            } else {
                camera.postSet(propertyId: propId, value: value.uint32Value)
            }
        } label: {
            Text(valueStr)
                // Single weight everywhere — bolding only the centre
                // would force a non-animatable font change on every
                // wheel rotation. Keeping every slot bold gives the
                // sliding ribbon a uniform appearance.
                .font(.callout.monospacedDigit().bold())
                // Single foreground; contrast comes entirely from
                // the `.opacity` modifier below, which IS animatable.
                .foregroundStyle(.primary)
                .frame(width: slotWidth, height: chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .offset(x: CGFloat(dx) * slotWidth)
        // Hit-test only the slots the user can actually see. When
        // collapsed: only the centre. When expanded: centre and
        // immediate neighbours. Buffer slots (|dx| > 1) pass clicks
        // through so the user can't accidentally invoke a SET on an
        // invisible value.
        .allowsHitTesting(absDx <= (isExpanded ? 1 : 0))
    }

    /// Pick a slot width that fits the widest enum value's formatted
    /// string at the wheel's font/weight. Done once per render —
    /// cheap because enum lists are typically < 50 entries.
    /// Approximation; we use NSAttributedString.size as the truth
    /// rather than a character-count heuristic so weird-width values
    /// like "+1.0 EV" or "Aperture Priority Mode" still get a slot
    /// that actually contains them.
    private func computeSlotWidth(for values: [NSNumber]) -> CGFloat {
        // Measure with bold monospaced-digit at callout size — that's
        // the centre-slot styling, the widest the value will ever be
        // rendered. Sizing slots to fit the bold variant means the
        // regular-weight side slots have a little extra breathing
        // room, which looks fine.
        let pointSize = NSFont.preferredFont(forTextStyle: .callout).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .bold)
        var maxWidth: CGFloat = 0
        for value in values {
            let str = formatExtPropRaw(value, propId: propId, vendor: camera.vendor)
            let width = (str as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth { maxWidth = width }
        }
        // Small horizontal breathing room (6 pt total = 3 each side)
        // so the text isn't flush against the slot edges. The
        // lower bound (26 pt) keeps very short values like "100" or
        // "f/4" from collapsing to an awkwardly narrow slot.
        return max(26, ceil(maxWidth) + 6)
    }
}

// MARK: - Tune chip (colour matrix / bar)

/// Pill chip for WB tune properties. Two layouts depending on
/// `TuneStyle`, both following the same collapsed/expanded pattern
/// as the regular `ChipPill`:
///
///   • Collapsed: a single colour swatch the size of the chip's
///     label row, showing the colour at the property's current
///     value. Same for both `.bar1D` and `.grid2D`.
///   • Expanded (`.bar1D`): inline 13-cell strip on the
///     green↔magenta axis, current cell highlighted, click any cell
///     to step the value.
///   • Expanded (`.grid2D`): SwiftUI popover with the full 13×13
///     colour matrix, click any cell to set the value.
///
/// Sharing the `expandedPropId` binding with `ChipPill` means at
/// most one chip (any kind) is open across the whole HUD; clicking
/// another chip collapses this one, and the hover-out debounce
/// timer also works the same way.
private struct TuneChip: View {
    let label: String
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    let style: TuneStyle
    @Binding var expandedPropId: UInt32?

    /// Debounced collapse-on-hover-leave (same timer pattern as
    /// `ChipPill`). 150 ms grace window so the cursor brushing the
    /// pill's rounded edge or briefly leaving during cell taps
    /// doesn't snap the chip shut mid-interaction.
    @State private var pendingCollapse: DispatchWorkItem?
    private let hoverOutCollapseDelay: TimeInterval = 0.15

    /// Match `ChipPill.chipHeight` so tune chips line up vertically
    /// with their neighbours in the same row.
    private let chipHeight: CGFloat = 18

    var body: some View {
        let isExpanded = (expandedPropId == propId)
        // 2D-matrix expansion completely replaces the chip's regular
        // [label][swatch] row with just the matrix — the user's
        // preference, since the matrix conveys the value visually
        // and the label / swatch would just be redundant noise above
        // it. 1D bar expansion keeps the [label][bar] row layout
        // because the bar is narrow enough that it fits next to the
        // label without crowding.
        let showMatrix: Bool = {
            if case .grid2D = style { return isExpanded }
            return false
        }()
        // Conditional swap — when expanded as a 2D matrix the row
        // HStack disappears entirely (no zero-sized leftover view in
        // the tree) and the matrix takes its place. Tried a ZStack
        // with both branches always present and toggled via opacity
        // + zero-frame; produced subtle hit-testing weirdness when
        // clicking the swatch in collapsed state, since the
        // off-screen matrix branch still wanted to participate in
        // layout queries. Plain `if` is cleaner.
        Group {
            if showMatrix, case .grid2D(let rMax) = style {
                TuneGridStrip(camera: camera, propId: propId, prop: prop,
                              rangeMax: rMax)
            } else {
                HStack(spacing: 4) {
                    labelSegment(isExpanded: isExpanded)
                    content(isExpanded: isExpanded)
                }
                // Disable inner hit-testing while collapsed so the
                // label and the swatch can't grab clicks (SwiftUI
                // Buttons flash a press visual that the user reads
                // as a glitch). The chip's outer .onTapGesture
                // catches the click and expands. When the 1D bar
                // is expanded the bar cells need to be tappable to
                // set values, so re-enable then.
                .allowsHitTesting(isExpanded)
            }
        }
        // When the chip holds the 2D matrix it gets more generous
        // padding so the grid sits inside a balanced frame; when
        // it's just the row, keep the tighter chip-style padding so
        // it lines up with the other capsule chips next to it.
        .padding(.horizontal, showMatrix ? 8 : 6)
        .padding(.vertical, showMatrix ? 8 : 3)
        // Corner radius: chip's total height is `chipHeight + 2 ×
        // verticalPadding` = 18 + 6 = 24 pt for the row chip, so a
        // proper capsule needs radius = 12. Using `chipHeight / 2`
        // alone (= 9) ignored the padding and produced a too-sharp
        // rounded-rect end. Matrix variant uses the same 12 pt
        // since that ALSO works for the larger block (gentle
        // rounded-square; capsule rounding scaled with height
        // would look weirdly bulgy on a near-square chip).
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        // The entire pill is a tap target. Without this, the
        // HStack's inter-child spacing (the gap between the label
        // and the swatch / bar) was outside any inner Button, so
        // clicks there passed through to the PreviewView's
        // mouseDown and toggled the HUD off — surprising, since
        // the chip looks like one continuous control. Inner
        // Buttons (label, swatch, bar cells) still take priority
        // because SwiftUI matches inner gestures first; this
        // gesture only fires on the gap / pill background.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            // Only expand from a tap on the dead pill area; never
            // collapse via the same tap. Collapse stays the
            // hover-out behaviour, matching the regular ChipPill.
            if expandedPropId != propId {
                expandedPropId = propId
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        .onHover { hovering in
            pendingCollapse?.cancel()
            pendingCollapse = nil
            if hovering { return }
            guard expandedPropId == propId else { return }
            let task = DispatchWorkItem {
                if expandedPropId == propId { expandedPropId = nil }
            }
            pendingCollapse = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverOutCollapseDelay,
                                          execute: task)
        }
    }

    private func labelSegment(isExpanded: Bool) -> some View {
        Button {
            expandedPropId = isExpanded ? nil : propId
        } label: {
            Text(label)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.primary)
                .opacity(0.6)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(isExpanded: Bool) -> some View {
        // The top row of the chip (label + a single swatch or a
        // strip of cells). For .grid2D the full matrix lives in
        // the chip's outer VStack below this row when expanded —
        // see `body`.
        switch style {
        case .bar1D(let rMin, let rMax):
            if isExpanded {
                TuneBarStrip(camera: camera, propId: propId, prop: prop,
                             rangeMin: rMin, rangeMax: rMax,
                             cellHeight: chipHeight)
            } else {
                collapsedSwatchBar1D(rangeMin: rMin, rangeMax: rMax,
                                     isExpanded: isExpanded)
            }
        case .grid2D(let rMax):
            collapsedSwatchGrid2D(rangeMax: rMax, isExpanded: isExpanded)
        }
    }

    /// Collapsed swatch for a 1D bar: a single cell coloured at the
    /// current value's position on the green↔magenta axis. Clicking
    /// expands the chip to the full 13-cell strip.
    private func collapsedSwatchBar1D(rangeMin: Int, rangeMax: Int,
                                      isExpanded: Bool) -> some View {
        let span = max(1, rangeMax - rangeMin)
        let t = max(0.0, min(1.0, Double(prop.value.intValue - rangeMin) / Double(span)))
        return Button {
            expandedPropId = isExpanded ? nil : propId
        } label: {
            // Softer corners than the in-bar cells so the swatch
            // matches the chip pill's overall rounded-pill curve
            // when collapsed. Picked ~30% of the swatch's side
            // length so the rounding reads at any chip size.
            TuneCellSwatch(
                color: greenMagentaColor(t: t),
                size: chipHeight - 2,
                isCurrent: true,
                cornerRadius: 5)
        }
        .buttonStyle(.plain)
    }

    /// Collapsed swatch for a 2D grid: a single cell coloured at the
    /// current value's position on the full blue↔orange × green↔magenta
    /// matrix. Clicking opens the popover with the full 13×13 grid.
    private func collapsedSwatchGrid2D(rangeMax: Int,
                                       isExpanded: Bool) -> some View {
        let (cx, cy) = decodeGrid2D(value: prop.value.intValue, rangeMax: rangeMax)
        return Button {
            expandedPropId = isExpanded ? nil : propId
        } label: {
            // Same softer rounding as the 1D collapsed swatch
            // (see `collapsedSwatchBar1D`) — visually consistent
            // across tune chips of either style.
            TuneCellSwatch(
                color: matrixColor(xt: gridFraction(cx),
                                   yt: gridFraction(cy)),
                size: chipHeight - 2,
                isCurrent: true,
                cornerRadius: 5)
        }
        .buttonStyle(.plain)
    }
}

/// Inline 13-cell strip on the green↔magenta axis. Each cell maps
/// to a portion of the property's full range; clicking sets the
/// value to that cell's representative. For tunes whose native
/// range is exactly 13 steps (Nikon ±6) every cell is one value.
/// For wider ranges (Sony 0..255) cells span multiple raw values.
private struct TuneBarStrip: View {
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    let rangeMin: Int
    let rangeMax: Int
    let cellHeight: CGFloat

    private let cellCount = 13
    private let cellSpacing: CGFloat = 1

    var body: some View {
        let currentValue = prop.value.intValue
        let currentIdx = cellIndex(forValue: currentValue)
        let side = cellHeight - 4  // square cells, slightly inset
        HStack(spacing: cellSpacing) {
            ForEach(0..<cellCount, id: \.self) { idx in
                let t = Double(idx) / Double(cellCount - 1)
                Button {
                    camera.postSet(propertyId: propId,
                                   value: UInt32(value(forCellIndex: idx)))
                } label: {
                    TuneCellSwatch(
                        color: greenMagentaColor(t: t),
                        size: side,
                        isCurrent: idx == currentIdx)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    /// Map a property value to the cell whose representative is
    /// closest to it. Round-trip-safe: `value(forCellIndex(cellIndex(v)))`
    /// returns the canonical representative for that cell.
    private func cellIndex(forValue value: Int) -> Int {
        let span = max(1, rangeMax - rangeMin)
        let normalized = Double(value - rangeMin) / Double(span)
        let raw = Int(round(normalized * Double(cellCount - 1)))
        return max(0, min(cellCount - 1, raw))
    }

    private func value(forCellIndex idx: Int) -> Int {
        let normalized = Double(idx) / Double(cellCount - 1)
        return rangeMin + Int(round(normalized * Double(rangeMax - rangeMin)))
    }
}

/// Inline 13×13 colour matrix for `.grid2D` tunes. Rendered below
/// the chip's swatch row when the chip is expanded — same
/// in-place expansion model as the 1D bar. Click any cell to set
/// the value. Coloured exactly like the legacy `WbTuneGridView`
/// (NSColor blending of blue↔orange on X and green↔magenta on Y)
/// so the HUD's tune picker is visually continuous with the
/// menu's.
private struct TuneGridStrip: View {
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    let rangeMax: Int

    private let gridSize = 13
    private let cellSize: CGFloat = 16
    private let cellSpacing: CGFloat = 1

    var body: some View {
        let currentValue = prop.value.intValue
        VStack(spacing: cellSpacing) {
            // `dlY` follows the WbTuneGridView's draw-loop convention
            // (0 = visually top row), and `encodeGrid2D` uses the same
            // orientation — important so the cell the user clicks
            // matches the value the camera actually receives.
            ForEach(0..<gridSize, id: \.self) { dlY in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<gridSize, id: \.self) { x in
                        let tX = gridFraction(x)
                        let tY = gridFraction(dlY)
                        // Direct value comparison: encode this
                        // cell's (x, dlY) into a PTP value and
                        // compare to the property's current value.
                        // Matches `WbTuneGridView.draw`'s
                        // `val == currentValue` check so the HUD's
                        // grid highlights bit-exactly the cell the
                        // menu would highlight for the same camera
                        // state.
                        let cellValue = encodeGrid2D(x: x, y: dlY, rangeMax: rangeMax)
                        let isCurrent = (cellValue == currentValue)
                        Button {
                            camera.postSet(propertyId: propId, value: UInt32(cellValue))
                        } label: {
                            TuneCellSwatch(
                                color: matrixColor(xt: tX, yt: tY),
                                size: cellSize,
                                isCurrent: isCurrent)
                        }
                        .buttonStyle(.plain)
                        // Suppress macOS keyboard-focus ring;
                        // otherwise the first interactive cell
                        // picks up a focus highlight on appearance
                        // that reads as a spurious "current cell"
                        // marker on the (0,0) corner.
                        .focusable(false)
                    }
                }
            }
        }
    }
}

/// One filled square with a white outline when it represents the
/// currently-selected value. Shared between the inline bar cells,
/// the matrix cells, and the collapsed chip swatch — the
/// `cornerRadius` argument lets the collapsed swatch pick a
/// softer rounding that matches the chip's outer corner curve,
/// while the matrix/bar cells stay tightly rounded so the grid
/// reads as a continuous colour field.
private struct TuneCellSwatch: View {
    let color: Color
    let size: CGFloat
    let isCurrent: Bool
    let cornerRadius: CGFloat

    init(color: Color, size: CGFloat, isCurrent: Bool, cornerRadius: CGFloat = 1.5) {
        self.color = color
        self.size = size
        self.isCurrent = isCurrent
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isCurrent ? Color.white : Color.clear,
                            lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

// MARK: - Tune helpers (colour, encoding)

/// Decode a 2D grid value to its draw-loop (x, y) cell. `y=0` is
/// the visually top row, matching `WbTuneGridView.valueFrom`. The
/// two encodings the menu's grid view recognises:
///   • `rangeMax=168` (Nikon dense): `value = x + y*13`
///   • `rangeMax=1224` (Sony sparse): `value = x*2 + y*100`
private func decodeGrid2D(value: Int, rangeMax: Int) -> (x: Int, y: Int) {
    let gridSize = 13
    if rangeMax == 168 {
        let y = max(0, min(gridSize - 1, value / gridSize))
        let x = max(0, min(gridSize - 1, value - y * gridSize))
        return (x, y)
    }
    if rangeMax == 1224 {
        let y = max(0, min(gridSize - 1, value / 100))
        let x = max(0, min(gridSize - 1, (value - y * 100) / 2))
        return (x, y)
    }
    return (0, 0)
}

/// Inverse of `decodeGrid2D`. Produces the canonical PTP value
/// for a grid cell — what `postSet` should send when the user
/// clicks a cell.
private func encodeGrid2D(x: Int, y: Int, rangeMax: Int) -> Int {
    if rangeMax == 168  { return x + y * 13 }
    if rangeMax == 1224 { return x * 2 + y * 100 }
    return 0
}

/// 0..1 fraction of a grid coordinate (used for colour blending).
private func gridFraction(_ idx: Int) -> Double {
    let gridSize = 13
    return Double(idx) / Double(gridSize - 1)
}

/// Colour used in the 2D grid swatches. Bilinear blend of four
/// corner colours sized so the matrix centre — which represents
/// "no fine-tune offset" — is exact neutral gray `(0.5, 0.5, 0.5)`:
///
///   • X axis: `blue (0,0,1)` ↔ `yellow (1,1,0)` — true RGB
///     complements, so they average to gray. Visually still reads
///     as the amber↔blue temperature axis cameras use (yellow at
///     the warm end, blue at the cool end).
///   • Y axis: `green (0,1,0)` ↔ `magenta (1,0,1)` — already
///     complements.
///
/// Corner colours after the per-axis 50/50 blends:
///
///   • TL `(xt=0, yt=0)`: blue+green   = (0.0, 0.5, 0.5)
///   • TR `(xt=1, yt=0)`: yellow+green = (0.5, 1.0, 0.0)
///   • BL `(xt=0, yt=1)`: blue+magenta = (0.5, 0.0, 1.0)
///   • BR `(xt=1, yt=1)`: yellow+magenta = (1.0, 0.5, 0.5)
///   • Centre = average = (0.5, 0.5, 0.5) ✓
///
/// Direct sRGB linear interpolation (rather than `NSColor.blended`)
/// because `NSColor.blended` blends in the source's colour space
/// and applies gamma correction along the way, which shifts the
/// nominal `(0.5, 0.5, 0.5)` blend off-gray when rendered.
/// Computing the interpolation here in straight RGB and handing
/// SwiftUI's `Color(red:green:blue:)` (sRGB by default) the
/// finished values keeps the centre cell perceptually neutral.
private func matrixColor(xt: Double, yt: Double) -> Color {
    let tl: (Double, Double, Double) = (0.0, 0.5, 0.5)
    let tr: (Double, Double, Double) = (0.5, 1.0, 0.0)
    let bl: (Double, Double, Double) = (0.5, 0.0, 1.0)
    let br: (Double, Double, Double) = (1.0, 0.5, 0.5)
    let top = lerpRGB(tl, tr, t: xt)
    let bot = lerpRGB(bl, br, t: xt)
    let mid = lerpRGB(top, bot, t: yt)
    return Color(red: mid.0, green: mid.1, blue: mid.2)
}

/// Pure green↔magenta blend for the 1D inline bar — same Y axis
/// the matrix uses, with X fixed at the neutral midpoint. By
/// direct RGB interpolation (`green (0,1,0)` ↔ `magenta (1,0,1)`)
/// the centre `t=0.5` lands on exactly `(0.5, 0.5, 0.5)`.
private func greenMagentaColor(t: Double) -> Color {
    let g: (Double, Double, Double) = (0.0, 1.0, 0.0)
    let m: (Double, Double, Double) = (1.0, 0.0, 1.0)
    let mid = lerpRGB(g, m, t: t)
    return Color(red: mid.0, green: mid.1, blue: mid.2)
}

/// Component-wise linear interpolation between two RGB triplets.
/// Kept as a tuple-of-Double helper rather than wrapping in a
/// struct so the per-cell colour computation in the matrix bilinear
/// blend stays a one-liner.
private func lerpRGB(_ a: (Double, Double, Double),
                     _ b: (Double, Double, Double),
                     t: Double)
    -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t,
     a.1 + (b.1 - a.1) * t,
     a.2 + (b.2 - a.2) * t)
}

// MARK: - Color-temperature chip + Planckian-locus picker

/// Chip for Kelvin-valued properties (Nikon 0xD01E, Sony 0xD20F).
/// Collapsed: a label + the current temperature text (e.g.
/// "CT  5500K"). Expanded: a small CIE-style colour diagram with
/// the Planckian locus drawn through it; dragging along the locus
/// updates the camera's WB Kelvin to the matched point's
/// temperature. Same chip lifecycle (expand on outer tap,
/// collapse on hover-out) as the tune chips.
private struct ColorTemperatureChip: View {
    let label: String
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    @Binding var expandedPropId: UInt32?

    @State private var pendingCollapse: DispatchWorkItem?
    private let hoverOutCollapseDelay: TimeInterval = 0.15
    private let chipHeight: CGFloat = 18

    var body: some View {
        let isExpanded = (expandedPropId == propId)
        Group {
            if isExpanded {
                // Default Kelvin range when the property descriptor
                // doesn't supply one — covers the common camera
                // span (tungsten 2500K → daylight-bluesky 10000K).
                // Real cameras typically report 2500..10000 with
                // 100K steps for 0xD01E and similar for 0xD20F.
                let rMin = prop.rangeMin?.intValue ?? 2500
                let rMax = prop.rangeMax?.intValue ?? 10000
                let step = max(1, prop.rangeStep?.intValue ?? 100)
                PlanckianLocusView(
                    rangeMin: rMin, rangeMax: rMax, step: step,
                    currentKelvin: prop.value.intValue
                ) { newKelvin in
                    camera.postSet(propertyId: propId, value: UInt32(newKelvin))
                }
            } else {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.primary).opacity(0.6)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: chipHeight)
                    Text("\(prop.value.intValue)K")
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(.primary)
                        .frame(height: chipHeight)
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, isExpanded ? 8 : 6)
        .padding(.vertical, isExpanded ? 8 : 3)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if expandedPropId != propId {
                expandedPropId = propId
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        .onHover { hovering in
            pendingCollapse?.cancel()
            pendingCollapse = nil
            if hovering { return }
            guard expandedPropId == propId else { return }
            let task = DispatchWorkItem {
                if expandedPropId == propId { expandedPropId = nil }
            }
            pendingCollapse = task
            DispatchQueue.main.asyncAfter(
                deadline: .now() + hoverOutCollapseDelay, execute: task)
        }
    }
}

// MARK: - Planckian locus geometry + colour

/// Cubic approximations of the CIE 1931 Planckian locus
/// chromaticity coordinates, from Kim et al. (2002). Same
/// piecewise polynomial split the camera-science world uses for
/// "blackbody temperature → CIE (x, y)" conversions.
///
/// Returns the chromaticity (x, y) for the given correlated colour
/// temperature in Kelvin. Valid for ~1667–25000 K; outside that
/// range the polynomial fit degrades but doesn't blow up.
private func planckianChromaticity(kelvin t: Double) -> (x: Double, y: Double) {
    let invT  = 1.0 / t
    let invT2 = invT * invT
    let invT3 = invT2 * invT
    let x: Double
    if t < 4000 {
        x = -0.2661239e9 * invT3 - 0.2343589e6 * invT2 + 0.8776956e3 * invT + 0.179910
    } else {
        x = -3.0258469e9 * invT3 + 2.1070379e6 * invT2 + 0.2226347e3 * invT + 0.240390
    }
    let x2 = x * x
    let x3 = x2 * x
    let y: Double
    if t < 2222 {
        y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
    } else if t < 4000 {
        y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
    } else {
        y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
    }
    return (x, y)
}

/// Convert CIE 1931 (x, y) chromaticity coordinates (assuming
/// Y = 1) to an sRGB Color suitable for rendering. Uses the
/// standard sRGB transformation matrix, clips out-of-gamut
/// values, and equalises perceived luminance across all
/// chromaticities so the rendered field reads as a smooth field
/// of colours instead of having a bright white-point peak.
///
/// Without the luminance-equalisation pass the previous
/// max-channel normalisation meant every chromaticity was "fully
/// on" in at least one channel, but their *relative luminances*
/// still varied (white Y = 1.0, saturated blue Y ≈ 0.07). That's
/// why the 6500 K white area used to outshine the cool blue / warm
/// orange ends in the rendered diagram. Forcing every output
/// chromaticity to the same target `Y` makes the field read
/// evenly: dim the white area, brighten saturated areas by
/// blending in white (pastel-ising them) — preserving hue while
/// matching luminance.
private func chromaticityRGB(x: Double, y: Double) -> (Double, Double, Double) {
    guard y > 0 else { return (0, 0, 0) }
    // XYZ with Y = 1
    let X = x / y
    let Y = 1.0
    let Z = (1 - x - y) / y
    // sRGB linear (D65 reference white)
    var r =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    var g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    var b =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    // Clip out-of-gamut negatives (these chromaticities can't be
    // displayed faithfully on sRGB; clipping projects them to the
    // nearest reachable hue).
    r = max(0, r); g = max(0, g); b = max(0, b)
    // Normalise to brightest channel = 1 so saturated colours
    // don't render as a near-black sliver of their natural Y.
    let maxC = max(r, max(g, b))
    if maxC > 0 { r /= maxC; g /= maxC; b /= maxC }
    // Equalise to a target perceived luminance. Rec. 709 / sRGB
    // luminance coefficients (these match the green-heavy weight
    // human eyes assign to each primary). 0.55 is bright enough
    // that the field still feels colourful but dim enough that the
    // overlay locus and marker pop visually against it.
    let targetY: Double = 0.55
    let currentY = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if currentY > 0 {
        if currentY >= targetY {
            // Bright chromaticity — scale all channels down.
            let scale = targetY / currentY
            r *= scale; g *= scale; b *= scale
        } else if currentY < 1 {
            // Dim chromaticity — blend toward white to raise
            // luminance to the target. Algebra: for
            // c' = (1-t)·c + t·1, the equation
            // (1-t)·Y + t·1 = targetY  solves to
            // t = (targetY − Y) / (1 − Y).
            let t = (targetY - currentY) / (1 - currentY)
            r = (1 - t) * r + t
            g = (1 - t) * g + t
            b = (1 - t) * b + t
        }
    }
    // sRGB gamma encode.
    func encode(_ u: Double) -> Double {
        u <= 0.0031308 ? 12.92 * u : 1.055 * pow(u, 1 / 2.4) - 0.055
    }
    return (encode(r), encode(g), encode(b))
}

/// CIE-style picker for camera WB color temperature. Shows the
/// Planckian locus drawn through a chromaticity-coloured area;
/// dragging along the curve maps the cursor position to a Kelvin
/// value and posts it to the camera.
///
/// Implementation notes:
///   • The locus is sampled at every available step in the
///     property's range (`rangeMin … rangeMax` in `step`-K
///     increments) so the user can pick any value the camera
///     actually supports — no extra rounding needed.
///   • Each sample maps to a `(view-x, view-y)` position via the
///     fitted Planckian polynomial; we use the chromaticity
///     extents of the sampled range to fill the view.
///   • Drag location → nearest sample's CT. Dragging shows the
///     proposed CT live via `proposedKelvin`; on drag-end we
///     post the value to the camera (which round-trips back
///     through `prop.value` and the marker re-anchors).
private struct PlanckianLocusView: View {
    let rangeMin: Int
    let rangeMax: Int
    let step: Int
    let currentKelvin: Int
    let onSelect: (Int) -> Void

    /// Live CT during drag — what the marker shows while the
    /// user's finger is down. Held set on drag-end too, so the
    /// marker doesn't briefly snap back to `currentKelvin` (which
    /// is still the camera's *previous* value at that point —
    /// `postSet` round-trips through the extension and only
    /// reflects back over the next state publish). Cleared by
    /// `.onChange(of: currentKelvin)` once the camera echoes
    /// back the new value.
    @State private var proposedKelvin: Int? = nil

    /// View dimensions. Wide enough that the locus has visible
    /// curvature, short enough that the chip doesn't dominate
    /// the preview.
    private let viewWidth: CGFloat = 220
    private let viewHeight: CGFloat = 110

    /// Inset around the chromaticity-fill area so the locus
    /// endpoints and marker have room from the chip's rounded
    /// corner / outline without clipping.
    private let inset: CGFloat = 14

    /// Locus geometry computed once per body evaluation. Holds
    /// the per-sample CT + view position, plus the chromaticity
    /// extents needed to drive both the locus mapping and the
    /// background chromaticity-fill rendering. Bundled so we
    /// don't recompute the polynomial fits and the min/max
    /// extents independently for each visual layer.
    private struct LocusGeometry {
        let samples: [(kelvin: Int, point: CGPoint)]
        let minX: Double
        let spanX: Double
        let minY: Double
        let spanY: Double
    }
    private var geometry: LocusGeometry {
        var chromPoints: [(t: Int, x: Double, y: Double)] = []
        var t = rangeMin
        while t <= rangeMax {
            let (x, y) = planckianChromaticity(kelvin: Double(t))
            chromPoints.append((t, x, y))
            t += step
        }
        guard let firstX = chromPoints.map(\.x).min(),
              let lastX = chromPoints.map(\.x).max(),
              let firstY = chromPoints.map(\.y).min(),
              let lastY = chromPoints.map(\.y).max() else {
            return LocusGeometry(samples: [], minX: 0, spanX: 1, minY: 0, spanY: 1)
        }
        // Pad the chromaticity window slightly so the locus
        // doesn't sit flush against the rendered chromaticity
        // background's edges — gives the diagram a bit of CIE
        // context (greens above the locus, magentas below).
        let pad: Double = 0.04
        let minX = firstX - pad
        let maxX = lastX + pad
        let minY = firstY - pad
        let maxY = lastY + pad
        let spanX = max(0.0001, maxX - minX)
        let spanY = max(0.0001, maxY - minY)
        let pts: [(Int, CGPoint)] = chromPoints.map { sample in
            let nx = (sample.x - minX) / spanX
            let ny = 1.0 - (sample.y - minY) / spanY
            let px = inset + CGFloat(nx) * (viewWidth - 2 * inset)
            let py = inset + CGFloat(ny) * (viewHeight - 2 * inset)
            return (sample.t, CGPoint(x: px, y: py))
        }
        return LocusGeometry(samples: pts, minX: minX, spanX: spanX, minY: minY, spanY: spanY)
    }

    /// Find the locus sample whose point is closest to the given
    /// drag location. Used to map a drag position to a CT — the
    /// user doesn't have to drag exactly on the curve.
    private func closestSample(in geom: LocusGeometry, to p: CGPoint) -> (kelvin: Int, point: CGPoint)? {
        var best: (kelvin: Int, point: CGPoint)?
        var bestDist = CGFloat.infinity
        for s in geom.samples {
            let dx = s.point.x - p.x
            let dy = s.point.y - p.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = s }
        }
        return best
    }

    private var displayedKelvin: Int { proposedKelvin ?? currentKelvin }

    var body: some View {
        let geom = geometry
        ZStack {
            chromaticityBackground(geom: geom)
            // Locus drawn as a single subtle white polyline. We
            // used to paint each segment with its own
            // chromaticity colour, but that made the cool / blue
            // end of the curve much dimmer than the warm end
            // (saturated blue has low perceived luminance) so it
            // read as a dark band — confusing next to the bright
            // chromaticity-fill background. Letting the
            // background carry the colour information and using
            // the stroke as a pure shape cue reads cleaner.
            locusPath(geom: geom)
            marker(geom: geom)
            readout
        }
        .frame(width: viewWidth, height: viewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let nearest = closestSample(in: geom, to: value.location) {
                        proposedKelvin = nearest.kelvin
                    }
                }
                .onEnded { value in
                    if let nearest = closestSample(in: geom, to: value.location) {
                        onSelect(nearest.kelvin)
                        // Keep `proposedKelvin` set so the marker
                        // stays where the user dropped it even
                        // though `currentKelvin` (= prop.value)
                        // still holds the OLD value for the time
                        // it takes the camera to round-trip.
                        // `.onChange(of: currentKelvin)` below
                        // clears it once the new value reflects
                        // back.
                        proposedKelvin = nearest.kelvin
                    }
                }
        )
        .onChange(of: currentKelvin) { newValue in
            // Camera echoed back the value we proposed during the
            // last drag — release the local hold so subsequent
            // dial-turns on the camera body or menu-driven
            // changes track normally.
            if let proposed = proposedKelvin, proposed == newValue {
                proposedKelvin = nil
            }
        }
    }

    // MARK: Layers

    /// CIE-style chromaticity field around the Planckian locus.
    /// Each cell of a small grid covering the view computes its
    /// chromaticity (x, y) by inverting the same locus→view map
    /// used for the curve sampling, then renders the sRGB colour
    /// at that chromaticity. Out-of-gamut chromaticities clip to
    /// a darker shade — those areas are intentionally a hint of
    /// "this isn't a real CIE colour" without rendering as black.
    private func chromaticityBackground(geom: LocusGeometry) -> some View {
        Canvas { context, size in
            // 1 pt cells — render at native point resolution so
            // the chromaticity field reads as a smooth colour
            // gradient with no visible cell boundaries. The
            // background is a one-shot draw (only re-renders on
            // chip expand or property publish, not on every
            // drag-frame), so 24k fills is fine for performance.
            let cellSize: CGFloat = 1
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for col in 0..<cols {
                let cellX = CGFloat(col) * cellSize
                let nx = Double((cellX + cellSize / 2 - inset) / max(1, viewWidth - 2 * inset))
                let chromX = geom.minX + max(0, min(1, nx)) * geom.spanX
                for row in 0..<rows {
                    let cellY = CGFloat(row) * cellSize
                    let ny = Double((cellY + cellSize / 2 - inset) / max(1, viewHeight - 2 * inset))
                    let chromY = geom.minY + (1.0 - max(0, min(1, ny))) * geom.spanY
                    let rgb = chromaticityRGB(x: chromX, y: chromY)
                    let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
                    context.fill(
                        Path(CGRect(x: cellX, y: cellY,
                                    width: cellSize, height: cellSize)),
                        with: .color(color))
                }
            }
        }
    }

    /// Subtle outline of the Planckian curve. White at low
    /// opacity reads against both bright (warm end) and dark
    /// (cool end) backgrounds without competing with the
    /// chromaticity colours.
    @ViewBuilder
    private func locusPath(geom: LocusGeometry) -> some View {
        if geom.samples.count >= 2 {
            Path { p in
                p.move(to: geom.samples.first!.point)
                for s in geom.samples.dropFirst() { p.addLine(to: s.point) }
            }
            .stroke(Color.white.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            // Subtle drop shadow so the curve lifts off the
            // chromaticity field on both bright (warm-end) and
            // saturated (cool-end) backgrounds, without needing
            // to crank the stroke opacity or thickness.
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
        }
    }

    @ViewBuilder
    private func marker(geom: LocusGeometry) -> some View {
        let target = displayedKelvin
        // Pick the sample whose Kelvin is closest to the displayed
        // value, in case the property's step doesn't divide
        // `displayedKelvin` evenly (rare, but possible if the
        // descriptor lies about its step).
        if let current = geom.samples.min(by: {
            abs($0.kelvin - target) < abs($1.kelvin - target)
        }) {
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(current.point)
                .allowsHitTesting(false)
        }
    }

    private var readout: some View {
        // Anchored at the top so the readout sits where the
        // chip's label + value pair would be in the collapsed
        // state — a chip that expands to the diagram doesn't
        // appear to move its primary readout around.
        Text("\(displayedKelvin)K")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .position(x: viewWidth / 2, y: 12)
            .allowsHitTesting(false)
    }
}

// MARK: - Autofocus trigger chip

/// Momentary-action chip that fires an AF cycle on the camera
/// when tapped. No expand/collapse state — it's a button, not a
/// property picker. Visually keeps the same capsule pill /
/// background-material treatment as the other chips so it reads
/// as a peer of the AF mode / WB chips next to it, just with an
/// icon instead of a label/value pair.
private struct AutofocusTriggerChip: View {
    let camera: ExtCamera

    /// Brief "just fired" highlight. Set true on tap, reset
    /// after a short delay. Gives the user visual confirmation
    /// the trigger went out, since the actual focus response
    /// happens on the camera body and may not produce any
    /// HUD-observable change.
    @State private var firedFlash: Bool = false

    /// Match `ChipPill.chipHeight` so the chip lines up
    /// vertically with the rest of the row.
    private let chipHeight: CGFloat = 18

    var body: some View {
        Button {
            camera.postAutofocusTrigger()
            firedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                firedFlash = false
            }
        } label: {
            Image(systemName: "viewfinder")
                .font(.callout.bold())
                .foregroundStyle(.primary)
                .opacity(firedFlash ? 0.5 : 1.0)
                .frame(height: chipHeight)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            firedFlash
                ? AnyShapeStyle(Color.white.opacity(0.25))
                : AnyShapeStyle(.ultraThinMaterial),
            in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.18), value: firedFlash)
    }
}
