// UsbCameraProtocol.swift
// Shared types and protocol for all USB PTP camera implementations in the CMIO extension.

import Foundation

// MARK: - UsbCameraProperty

struct UsbCameraProperty {
    let propertyId: UInt32
    let dataType: UInt16
    let writable: Bool
    let value: NSNumber
    let enumValues: [NSNumber]?
    let rangeMin: NSNumber?
    let rangeMax: NSNumber?
    let rangeStep: NSNumber?
    var incremental: Bool = false  // Sony: use SetPropStep instead of SetPropAbs
    var isButton: Bool = false     // Sony: button property, step by value directly
    /// Factory default reported by GetDevicePropDesc. Preserved so the PTP
    /// dump UI can show "Default: N / Current: M" alongside enum/range info
    /// — useful when adding support for new cameras (defaults reveal which
    /// codes the camera considers neutral / out-of-the-box).
    var defaultValue: NSNumber?
}

// MARK: - UsbCameraProtocol

protocol UsbCameraProtocol: AnyObject {
    var onJpegFrame: ((Data) -> Void)? { get set }
    var onPropertiesDiscovered: (([UInt32: UsbCameraProperty]) -> Void)? { get set }
    func openSessionAndDiscover()
    func startLiveView()
    func stopLiveView()
    func setProperty(propId: UInt32, value: UInt32, dataType: UInt16)
    /// Trigger an autofocus cycle. Vendor-specific (Nikon AfDrive, Sony
    /// AutofocusButton toggle, etc.). Default no-op.
    func triggerAutofocus()
    func close()
}

extension UsbCameraProtocol {
    func triggerAutofocus() { }
}

// MARK: - PtpPropParser

/// Minimal PTP data parser shared by all USB camera implementations.
class PtpPropParser {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    func readU8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let v = data[offset]; offset += 1; return v
    }
    func readU16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let v = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        offset += 2; return v
    }
    func readU32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << (i * 8) }
        offset += 4; return v
    }
    func readI8()  -> Int8?  { readU8().map  { Int8(bitPattern: $0) } }
    func readI16() -> Int16? { readU16().map { Int16(bitPattern: $0) } }
    func readI32() -> Int32? { readU32().map { Int32(bitPattern: $0) } }

    func readNum(ofType dt: UInt16) -> NSNumber? {
        switch dt {
        case 1: return readU8().map  { NSNumber(value: Int8(bitPattern: $0)) }
        case 2: return readU8().map  { NSNumber(value: $0) }
        case 3: return readU16().map { NSNumber(value: Int16(bitPattern: $0)) }
        case 4: return readU16().map { NSNumber(value: $0) }
        case 5: return readU32().map { NSNumber(value: Int32(bitPattern: $0)) }
        case 6: return readU32().map { NSNumber(value: $0) }
        default: return nil
        }
    }
    func skip(type dt: UInt16) { _ = readNum(ofType: dt) }

    @discardableResult
    func skipPtpString() -> Bool {
        guard let charCount = readU8() else { return false }
        guard offset + Int(charCount) * 2 <= data.count else { return false }
        offset += Int(charCount) * 2
        return true
    }

    /// Read a PTP string (UCS-2 LE, length-prefixed by a single byte that
    /// counts characters INCLUDING the trailing NUL). Returns the decoded
    /// string without the terminating NUL, or nil if the buffer is short.
    /// Empty strings (charCount == 0) decode to "".
    func readPtpString() -> String? {
        guard let charCount = readU8() else { return nil }
        if charCount == 0 { return "" }
        let byteCount = Int(charCount) * 2
        guard offset + byteCount <= data.count else { return nil }
        // Strip the trailing NUL character (2 bytes of 0x00).
        let payloadBytes = byteCount > 1 ? byteCount - 2 : byteCount
        let bytes = data.subdata(in: offset ..< offset + payloadBytes)
        offset += byteCount
        return String(data: bytes, encoding: .utf16LittleEndian)
    }

    func readU16Array() -> [UInt16]? {
        guard let count = readU32() else { return nil }
        var result: [UInt16] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let v = readU16() else { return nil }
            result.append(v)
        }
        return result
    }

    func skipArray(elementSize: Int) {
        guard let count = readU32() else { return }
        let skip = Int(count) * elementSize
        guard offset + skip <= data.count else { return }
        offset += skip
    }

    /// Parse a standard PTP GetPropDesc response into a UsbCameraProperty.
    func parsePropDesc() -> UsbCameraProperty? {
        guard let propId   = readU16(),
              let dataType = readU16(),
              let rwFlag   = readU8() else { return nil }
        let defaultValue = readNum(ofType: dataType)
        guard let currentValue = readNum(ofType: dataType) else { return nil }
        guard let formFlag = readU8() else { return nil }

        var enumValues: [NSNumber]?
        var rangeMin: NSNumber?
        var rangeMax: NSNumber?
        var rangeStep: NSNumber?

        if formFlag == 0x01 {
            rangeMin  = readNum(ofType: dataType)
            rangeMax  = readNum(ofType: dataType)
            rangeStep = readNum(ofType: dataType)
            if rwFlag != 0, let mn = rangeMin, let mx = rangeMax, let st = rangeStep {
                let minD = mn.doubleValue; let maxD = mx.doubleValue; let stepD = st.doubleValue
                if stepD > 0 {
                    let count = Int((maxD - minD) / stepD) + 1
                    if count >= 2 && count <= 64 {
                        var synth: [NSNumber] = []
                        for i in 0..<count { synth.append(NSNumber(value: minD + Double(i) * stepD)) }
                        enumValues = synth
                    }
                }
            }
        } else if formFlag == 0x02 {
            guard let count = readU16() else { return nil }
            var values: [NSNumber] = []
            for _ in 0..<count {
                if let v = readNum(ofType: dataType) { values.append(v) }
            }
            enumValues = values
        }

        return UsbCameraProperty(
            propertyId: UInt32(propId), dataType: dataType, writable: rwFlag != 0,
            value: currentValue, enumValues: enumValues,
            rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
            defaultValue: defaultValue)
    }
}

// MARK: - JPEG extraction (shared by all camera implementations)

/// Finds the last SOI…EOI region in a live view data blob.
func extractJpegFromLiveViewData(_ data: Data) -> Data? {
    let soi = Data([0xFF, 0xD8])
    let eoi = Data([0xFF, 0xD9])

    var lastSoi: Data.Index? = nil
    var search = data.startIndex
    while let r = data.range(of: soi, in: search ..< data.endIndex) {
        lastSoi = r.lowerBound
        search  = r.upperBound
    }
    guard let start = lastSoi else { return nil }
    let afterSoi = data.index(start, offsetBy: 2)
    guard afterSoi < data.endIndex else { return nil }
    guard let eoiRange = data.range(of: eoi, in: afterSoi ..< data.endIndex) else { return nil }
    return data[start ..< eoiRange.upperBound]
}
