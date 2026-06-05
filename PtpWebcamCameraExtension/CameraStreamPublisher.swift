// CameraStreamPublisher.swift
//
// Extension-side publisher for the stream protocol defined in
// `PtpCameraAgentProtocol.swift`. Transmits arbitrary-length binary
// payloads over a 256-slot Darwin notify chain, one slot post per
// 8 bytes of payload. Each slot has its own notify name so the
// kernel does NOT coalesce posts inside a single page. Cross-page
// coalescing on the same slot name is possible if a receiver
// stalls; the NACK / CRC feedback loop catches it.
//
// Why this exists: the previous "pages-in-a-single-notify-name"
// publisher relied on the receiver being able to read all slots
// before the publisher began overwriting the same slots for the
// next page. Under `.main`-queue UI load (SwiftUI re-layouts,
// AVCapture callbacks) the receiver could lag past the 60 ms
// inter-page gap and observe torn pages — visible in the field
// as a Nikon Z8 stuck in "Opening PTP session" because its
// 16.9 KB property snapshot spans two pages and the page-1
// writes raced page-0 reads. The per-slot-notify approach
// removes intra-page coalescing entirely; the rare cross-page
// race becomes a recoverable NACK round-trip.
//
// Single shared channel across cameras: different cameras'
// transmissions are serialised through the caller-supplied
// `publishQueue` (we don't own it; PtpWebcamCameraExtensionProvider
// passes in its existing one so the ordering against other
// publishers stays consistent).

import Foundation
import os.log

final class CameraStreamPublisher {
    // MARK: Token tables

    /// Notify tokens for the 256 stream slots. Index = slot index =
    /// per-page sequence number.
    private var slotTokens: [Int32] = []
    /// Names for those slots, kept around for `darwin_notify_post`
    /// (the post API takes the name, not the token).
    private var slotNames: [String] = []

    /// Token for the NACK slot value read.
    private var nackSlotToken: Int32 = 0
    /// Token for the NACK dispatch registration. Held so the
    /// closure stays alive for the publisher's lifetime.
    private var nackNotifyToken: Int32 = 0
    /// Per-marker control slot tokens. Each control type has
    /// its own notify name, so two control posts in the same
    /// transmission (e.g. start + end on a one-page payload)
    /// never coalesce against each other.
    private var startSlotToken: Int32 = 0
    private var endSlotToken:   Int32 = 0
    private var retxSlotToken:  Int32 = 0

    // MARK: Transmission state
    //
    // Accessed only on `publishQueue` (set by the caller via
    // `transmit(...)`) and on `nackQueue` (the NACK handler). The
    // two queues serialise around `stateLock`.

    private let stateLock = NSLock()
    /// Serialises ALL slot writes — forward passes from
    /// `transmit()` and NACK-triggered retransmits from
    /// `handleNack()`. Without this, a NACK that fires while the
    /// forward pass is still emitting pages had both threads
    /// writing the same 256 slot names concurrently, producing
    /// torn pages on the receiver and a cascade of further NACKs
    /// (page 6 → retransmit page 5..N races forward page 7..N
    /// → page 8 CRC fails → NACK 8 → loop forever). The lock is
    /// distinct from `stateLock` (which guards metadata only):
    /// holding it across a multi-second transmission would
    /// deadlock metadata reads from the NACK handler.
    private let sendLock = NSLock()
    /// Most recent dataset accepted for transmission. Retained
    /// after `transmit()` returns so a NACK arriving after the
    /// initial pass can still satisfy a retransmit. Replaced
    /// whole on each fresh `transmit()`; null between transmissions
    /// only at process start.
    private var currentData: Data?
    /// Total page count of `currentData`. Pre-computed once per
    /// transmission so the NACK handler doesn't have to redo
    /// the arithmetic.
    private var currentPageCount: UInt32 = 0
    /// Monotonic stamp incremented on every `transmit()`. NACKs
    /// captured under one stamp are ignored once `currentStamp`
    /// has advanced — they refer to a transmission the publisher
    /// has already moved past.
    private var currentStamp: UInt64 = 0

    // MARK: Queues

    /// Dedicated background queue for processing NACK callbacks.
    /// Not the same as the caller's publishQueue: we don't want a
    /// NACK to block the camera-state code path that's about to
    /// enqueue the next forward transmission.
    private let nackQueue = DispatchQueue(
        label: "org.ptpwebcam.cs.publisher.nack",
        qos: .userInteractive)

    /// Inter-packet delay between consecutive slot writes within
    /// a single page. The 256 slot names don't coalesce against
    /// each other, but the receiver's dispatch queue runs the
    /// closures serially — if posts arrive faster than the queue
    /// drains, libdispatch buffers them (no loss), but a longer
    /// drain cap on the receiver side increases the chance that
    /// the next page's writes overtake the prior page's reads.
    /// Empirically a tiny sleep here keeps the receiver caught
    /// up without measurably slowing the total transmission.
    private static let interPacketDelay: TimeInterval = 0.0001  // 100 µs
    /// Slightly longer settle between adjacent pages — drains
    /// the receiver queue before the next page reuses the
    /// 0..254 slot names.
    private static let interPageDelay:   TimeInterval = 0.001   // 1 ms
    /// Settle delay after the end-of-transmission marker, before
    /// `transmit()` returns and the next publish can begin.
    /// Without this, two back-to-back publishes (e.g. agent
    /// connects → publishCameraConnected immediately followed by
    /// publishPropertyState) both target the same end-marker
    /// notify name; the kernel coalesces them if the receiver's
    /// handler for the first hasn't drained yet, and the
    /// first-publish handler ends up reading the second
    /// publish's `totalLength`. 20 ms is well above any
    /// realistic dispatch latency on the receiver's
    /// userInteractive queue.
    private static let postEndMarkerDelay: TimeInterval = 0.020 // 20 ms

    private let log = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.CameraExtension",
                             category: "CameraStreamPublisher")

    // MARK: Init

    init() {
        slotTokens.reserveCapacity(kDarwinCameraStreamSlotCount)
        slotNames.reserveCapacity(kDarwinCameraStreamSlotCount)
        for i in 0..<kDarwinCameraStreamSlotCount {
            let name = kDarwinCameraStreamSlotPrefix + "\(i)"
            slotNames.append(name)
            var token: Int32 = 0
            darwin_notify_register_check(name, &token)
            slotTokens.append(token)
        }
        darwin_notify_register_check(kDarwinCameraStreamNackSlot, &nackSlotToken)
        darwin_notify_register_dispatch(kDarwinCameraStreamNack, &nackNotifyToken,
                                         nackQueue) { [weak self] _ in
            self?.handleNack()
        }
        // Control slots — one notify name per marker type. The
        // publisher only WRITES to these (the receiver listens),
        // so we only need `register_check` for the state tokens.
        darwin_notify_register_check(kDarwinCameraStreamStartSlot, &startSlotToken)
        darwin_notify_register_check(kDarwinCameraStreamEndSlot,   &endSlotToken)
        darwin_notify_register_check(kDarwinCameraStreamRetransmitSlot, &retxSlotToken)
    }

    // MARK: - Public API

    /// Transmit one full dataset. Synchronous on the caller's
    /// thread — the caller (extension provider) already runs
    /// publishes on its own serial `publishQueue`, so we don't
    /// double-buffer here.
    func transmit(_ data: Data) {
        // Hold `sendLock` for the duration of the forward pass so
        // a concurrent `handleNack` retransmit can't interleave
        // slot writes with this transmission. See `sendLock`'s
        // doc comment for the race this prevents.
        sendLock.lock()
        defer { sendLock.unlock() }

        // Snapshot under lock so a concurrent NACK can't see a
        // half-replaced `currentData`. The lock is released
        // before the actual posts because the lock is purely for
        // the state metadata, not for ordering against other
        // publishes (that's the caller's responsibility).
        let stamp: UInt64 = {
            stateLock.lock(); defer { stateLock.unlock() }
            currentData = data
            let pageCount = UInt32((data.count + kStreamPageSize - 1) / kStreamPageSize)
            currentPageCount = pageCount
            currentStamp &+= 1
            return currentStamp
        }()

        // Start-of-transmission marker. Carries `totalLength` so
        // the receiver can size each page's CRC input correctly
        // (matches the publisher's `data.prefix(pageEnd)` byte
        // count, including the truncated final page).
        let totalLength = UInt32(data.count)
        emitStartMarker(totalLength: totalLength, stamp: stamp)
        Thread.sleep(forTimeInterval: Self.interPageDelay)

        // Forward pass: 0 .. pageCount-1
        guard let pageCount = stateOf(stamp: stamp)?.pageCount else { return }
        for page in 0..<pageCount {
            sendPage(page, stamp: stamp)
            Thread.sleep(forTimeInterval: Self.interPageDelay)
            // The transmission may have been superseded mid-way
            // (a brand-new publish for another camera came in).
            // We can't actually pre-empt — the caller serialises
            // via `publishQueue` — but the check is cheap and
            // documents the assumption.
            guard stateOf(stamp: stamp) != nil else { return }
        }

        // End-of-transmission marker. Re-emits `totalLength` so
        // a receiver that joined mid-stream still has a final
        // size check.
        emitEndMarker(totalLength: totalLength)
        // See `postEndMarkerDelay` for the rationale: without this,
        // back-to-back transmissions can coalesce on the end-marker
        // notify name and the receiver reads the wrong totalLength.
        Thread.sleep(forTimeInterval: Self.postEndMarkerDelay)
    }

    // MARK: - Internals

    /// Returns the publisher's current state IFF `stamp` still
    /// matches (i.e. no newer `transmit()` has superseded it).
    /// Used as a cheap "should I keep going?" check inside the
    /// forward pass + NACK retransmit loops.
    private func stateOf(stamp: UInt64) -> (data: Data, pageCount: UInt32)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard stamp == currentStamp, let data = currentData else { return nil }
        return (data, currentPageCount)
    }

    /// Emit one numbered page: 255 data slot writes + 1 checkpoint
    /// slot write carrying the cumulative CRC through end-of-page.
    private func sendPage(_ page: UInt32, stamp: UInt64) {
        guard let (data, _) = stateOf(stamp: stamp) else { return }

        let pageStart = Int(page) * kStreamPageSize
        guard pageStart < data.count else { return }
        let pageEnd = min(pageStart + kStreamPageSize, data.count)

        // Data slots: one 8-byte chunk per slot, zero-padded at
        // the tail if this page is short.
        data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!
            for slotIdx in 0..<kStreamDataSlotCount {
                let chunkStart = pageStart + slotIdx * 8
                var value: UInt64 = 0
                if chunkStart < pageEnd {
                    let chunkSize = min(8, pageEnd - chunkStart)
                    memcpy(&value, base + chunkStart, chunkSize)
                }
                writeSlot(slotIdx: slotIdx, value: value)
            }
        }

        // Cumulative CRC up to end-of-page.
        let crc = ptpwebcamCRC32(data.prefix(pageEnd))
        writeCheckpoint(page: page, crc: crc)
    }

    /// Set + post a single stream slot. Each slot has its own
    /// Darwin notify name (no coalescing within a page).
    private func writeSlot(slotIdx: Int, value: UInt64) {
        darwin_notify_set_state(slotTokens[slotIdx], value)
        darwin_notify_post(slotNames[slotIdx])
        if Self.interPacketDelay > 0 {
            Thread.sleep(forTimeInterval: Self.interPacketDelay)
        }
    }

    /// Set + post the checkpoint slot (slot 255). The receiver
    /// reads page+CRC from this single slot, validates against
    /// the cumulative bytes it already accumulated, and either
    /// commits the buffer or NACKs the failing page.
    private func writeCheckpoint(page: UInt32, crc: UInt32) {
        writeSlot(slotIdx: kStreamCheckpointIndex,
                  value: packStreamCheckpoint(page: page, crc: crc))
    }

    /// Emit the start-of-transmission marker on its dedicated
    /// notify name. Value carries `totalLength` (lower 32 bits).
    /// Pack the 32-bit transmission stamp (low half of
    /// `currentStamp`) into the high 32 bits of the marker so the
    /// receiver can echo it back in any NACK it sends. Used by the
    /// publisher to discard stale NACKs that reference a prior
    /// transmission (see `handleNack`).
    private func emitStartMarker(totalLength: UInt32, stamp: UInt64) {
        let stampLow = UInt32(truncatingIfNeeded: stamp)
        let value = (UInt64(stampLow) << 32) | UInt64(totalLength)
        darwin_notify_set_state(startSlotToken, value)
        darwin_notify_post(kDarwinCameraStreamStart)
        if Self.interPacketDelay > 0 {
            Thread.sleep(forTimeInterval: Self.interPacketDelay)
        }
    }

    /// Emit the end-of-transmission marker on its dedicated
    /// notify name. Value carries `totalLength` (same as start
    /// marker, so the receiver can do a final length-mismatch
    /// check).
    private func emitEndMarker(totalLength: UInt32) {
        darwin_notify_set_state(endSlotToken, UInt64(totalLength))
        darwin_notify_post(kDarwinCameraStreamEnd)
        if Self.interPacketDelay > 0 {
            Thread.sleep(forTimeInterval: Self.interPacketDelay)
        }
    }

    /// Emit the retransmit-start marker on its dedicated notify
    /// name. Value carries the page index we're rewinding to
    /// (lower 24 bits), so the receiver knows where to expect
    /// the next page data to land.
    private func emitRetransmitMarker(rewindToPage: UInt32) {
        darwin_notify_set_state(retxSlotToken, UInt64(rewindToPage & 0xFFFFFF))
        darwin_notify_post(kDarwinCameraStreamRetransmit)
        if Self.interPacketDelay > 0 {
            Thread.sleep(forTimeInterval: Self.interPacketDelay)
        }
    }

    // MARK: - NACK handler

    /// Read the page index out of the NACK slot and, if it still
    /// corresponds to data we have on hand, retransmit from
    /// (nack-1) through the rest of the current dataset. The
    /// "rewind by one page" gives the receiver a known-good
    /// prior page (the one whose CRC already passed) to baseline
    /// against — same policy the project owner asked for.
    private func handleNack() {
        // Serialise the retransmit against any in-flight forward
        // pass — without this, both threads write the same 256
        // slot names concurrently and the receiver sees torn
        // pages. The lock may be held by `transmit()` for the
        // duration of a multi-page publish; that's fine, the
        // NACK just waits its turn (and by the time we get the
        // lock the receiver may have already validated the page
        // via the forward pass, in which case the stale NACK is
        // a no-op — the stamp check below covers that path).
        sendLock.lock()
        defer { sendLock.unlock() }

        var raw: UInt64 = 0
        darwin_notify_get_state(nackSlotToken, &raw)
        let nackPage = UInt32(raw & 0xFFFFFF)
        // The receiver puts the start marker's stamp (low 32
        // bits of currentStamp at the time the start marker
        // fired) into the high 32 bits of the NACK slot. We
        // reject any NACK whose stamp doesn't match our current
        // stamp — that means the NACK was sent against a prior
        // transmission whose data we no longer have, and a
        // retransmit against the CURRENT data would be wrong
        // bytes for the receiver's expected stream (the symptom
        // was an infinite NACK loop after two back-to-back
        // publishes of different snapshots).
        let nackStamp = UInt32(truncatingIfNeeded: raw >> 32)
        let stamp = currentStamp
        let currentStampLow = UInt32(truncatingIfNeeded: stamp)
        guard nackStamp == currentStampLow else {
            log.info("NACK page=\(nackPage) ignored — stamp=\(nackStamp) ≠ current=\(currentStampLow)")
            return
        }

        guard let state = stateOf(stamp: stamp) else {
            log.info("NACK page=\(nackPage) ignored — transmission already superseded")
            return
        }
        guard nackPage < state.pageCount else {
            log.info("NACK page=\(nackPage) ignored — outside current pageCount=\(state.pageCount)")
            return
        }

        // NACK page=0 is the receiver's "full restart" request,
        // sent when it can't recover from where it is (e.g., a
        // length-mismatch end-of-stream put it back into `.idle`
        // and the cumulative CRC baseline is gone). A
        // retransmit-marker-only approach can't recover from
        // that — the receiver's idle state means it'll drop the
        // retransmit pages because it has no expectedTotalLength
        // and no cumulative-CRC baseline to validate against.
        // Treat NACK page=0 as a full re-do: emit a fresh start
        // marker (re-engages the receiver from idle), send every
        // page, emit the end marker. Effectively re-running
        // `transmit()` with the same stamp and data.
        if nackPage == 0 {
            let totalLength = UInt32(state.data.count)
            log.fault("NACK page=0 — full restart, \(state.pageCount, privacy: .public) page(s)")
            emitStartMarker(totalLength: totalLength, stamp: stamp)
            Thread.sleep(forTimeInterval: Self.interPageDelay)
            for p in 0..<state.pageCount {
                sendPage(p, stamp: stamp)
                Thread.sleep(forTimeInterval: Self.interPageDelay)
                guard stateOf(stamp: stamp) != nil else { return }
            }
            emitEndMarker(totalLength: totalLength)
            Thread.sleep(forTimeInterval: Self.postEndMarkerDelay)
            return
        }

        let resendFrom: UInt32 = nackPage - 1
        log.fault("NACK page=\(nackPage, privacy: .public) — partial retransmit from page=\(resendFrom, privacy: .public)")

        emitRetransmitMarker(rewindToPage: resendFrom)
        Thread.sleep(forTimeInterval: Self.interPageDelay)

        for p in resendFrom..<state.pageCount {
            sendPage(p, stamp: stamp)
            Thread.sleep(forTimeInterval: Self.interPageDelay)
            guard stateOf(stamp: stamp) != nil else { return }
        }
        // No end-of-stream marker here on purpose: the original
        // transmission's end-of-stream marker (or the next
        // transmission's start marker) bounds the stream from the
        // receiver's perspective. Emitting another EOS during a
        // retransmit would terminate the stream mid-data if the
        // receiver hadn't yet seen the original EOS.
    }
}
