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
        top: [.whiteBalance],
        bottom: [.shutterSpeed, .aperture, .iso, .exposureCompensation, .exposureMode]
    )
}

// MARK: - View

struct PreviewHud: View {
    let camera: ExtCamera?
    let layout: HudLayout
    let visible: Bool

    /// Which chip is currently expanded into the inline value wheel.
    /// `nil` = all chips collapsed. At most one chip can be expanded
    /// at a time; tapping another collapses the previous. Reset to
    /// nil whenever `visible` flips to false so the HUD comes back in
    /// a clean state next time.
    @State private var expandedRole: SemanticCameraProperty? = nil

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
            if !newValue { expandedRole = nil }
        }
        .animation(.easeInOut(duration: 0.18), value: visible)
    }

    /// One row of chips for the given roles. Roles whose property
    /// isn't present on this camera are skipped.
    @ViewBuilder
    private func chipGroup(for roles: [SemanticCameraProperty]) -> some View {
        let cam = camera
        let visibleRoles = roles.filter { role in
            cam?.propertyId(for: role) != nil
        }
        if !visibleRoles.isEmpty {
            HStack(spacing: 6) {
                ForEach(visibleRoles, id: \.self) { role in
                    if let cam,
                       let propId = cam.propertyId(for: role),
                       let prop = cam.properties[propId] {
                        ChipPill(role: role,
                                 camera: cam,
                                 propId: propId,
                                 prop: prop,
                                 expandedRole: $expandedRole)
                    }
                }
            }
            // Animate the row's layout when a chip expands/collapses.
            // Without this, only the chip whose `isExpanded` flips
            // animates its width — the OTHER chips snap into their
            // new x positions because nothing in their own bodies
            // changed. Attaching the animation here propagates the
            // transition through the HStack's relayout so every
            // chip slides smoothly into its new position alongside
            // the expanding/collapsing one.
            .animation(.easeInOut(duration: 0.22), value: expandedRole)
        }
    }
}

// MARK: - ChipPill

private struct ChipPill: View {
    let role: SemanticCameraProperty
    let camera: ExtCamera
    let propId: UInt32
    let prop: ExtCameraProperty
    @Binding var expandedRole: SemanticCameraProperty?

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
        let isExpanded = (expandedRole == role)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
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
            guard expandedRole == role else { return }
            let task = DispatchWorkItem {
                // Re-check on fire — a fresh hover-in could have
                // arrived before the timer ran on the main queue.
                if expandedRole == role {
                    expandedRole = nil
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
            expandedRole = isExpanded ? nil : role
        } label: {
            Text(role.displayName)
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
                expandedRole = isExpanded ? nil : role
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
