// PtpDumper.swift
// Generates a human-readable text dump of a PTP device's GetDeviceInfo
// response plus a GetDevicePropDesc descriptor for every supported property.
//
// Purpose: when a user plugs in a camera we don't have a UsbCamera subclass
// for yet, they can hit the app's "List PTP Properties" menu and produce this
// dump. The output gives us the full op + property landscape needed to add
// support for the new vendor/model — supported operations, supported property
// codes, data types, current values, enums, and ranges.
//
// Only uses standard PTP opcodes (0x1002 OpenSession, 0x1001 GetDeviceInfo,
// 0x1014 GetDevicePropDesc, 0x1003 CloseSession) so it works against any
// PTP-compliant device. Vendor-specific handshakes (Sony SDIO Connect,
// Canon EOS init) are skipped intentionally: their results are documented
// once we add a UsbCamera subclass for the vendor.

import Foundation

final class PtpDumper {

    private let transport: UsbPtpTransport
    private var out = ""

    init(transport: UsbPtpTransport) {
        self.transport = transport
    }

    /// Perform the dump. Always returns a non-empty string (success or error
    /// description) suitable for displaying to the user.
    func run() -> String {
        out = ""
        let started = Date()

        line("PTP Property Dump")
        line("=================")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        line("Generated: \(formatter.string(from: started))")
        line("USB VID:PID: \(String(format: "%04X:%04X", transport.vendorId, transport.productId))")
        line("USB Product Name: \(transport.deviceName)")
        line("")

        // OpenSession is mandatory before any GetDevicePropDesc — many cameras
        // return DeviceBusy / SessionNotOpen errors otherwise. Try it once; if
        // the camera reports SessionAlreadyOpen, close and retry once.
        if !openSession() {
            line("ERROR: OpenSession failed — cannot continue.")
            return out
        }
        defer {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
        }

        guard dumpDeviceInfo() else {
            line("ERROR: GetDeviceInfo failed.")
            return out
        }

        dumpPropertyDescriptors()

        line("")
        line("--- End of Dump ---")
        line("Elapsed: \(String(format: "%.2f", -started.timeIntervalSinceNow))s")
        return out
    }

    // MARK: - Output helpers

    private func line(_ s: String = "") { out.append(s); out.append("\n") }

    // MARK: - Session

    private func openSession() -> Bool {
        for attempt in 1...2 {
            guard let (_, rsp) = try? transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1]))
            else { return false }
            let code = transport.responseCode(from: rsp)
            if code == PTP_RSP_OK { return true }
            if code == PTP_RSP_SESSIONALREADY && attempt == 1 {
                _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
                continue
            }
            line("OpenSession → 0x\(String(code, radix: 16))")
            return false
        }
        return false
    }

    // MARK: - GetDeviceInfo

    /// Cached supported-property list parsed from GetDeviceInfo.
    private var supportedPropIds: [UInt16] = []

    private func dumpDeviceInfo() -> Bool {
        guard let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_GETDEVICEINFO)),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else {
            return false
        }

        let p = PtpPropParser(data)
        let standardVersion = p.readU16() ?? 0
        let vendorExtId     = p.readU32() ?? 0
        let vendorExtVer    = p.readU16() ?? 0
        let vendorExtDesc   = p.readPtpString() ?? ""
        let functionalMode  = p.readU16() ?? 0
        let ops             = p.readU16Array() ?? []
        let events          = p.readU16Array() ?? []
        let propIds         = p.readU16Array() ?? []
        let captureFmts     = p.readU16Array() ?? []
        let imageFmts       = p.readU16Array() ?? []
        let manufacturer    = p.readPtpString() ?? ""
        let model           = p.readPtpString() ?? ""
        let deviceVersion   = p.readPtpString() ?? ""
        let serial          = p.readPtpString() ?? ""

        supportedPropIds = propIds

        line("=== Device Info ===")
        line("Manufacturer:           \(manufacturer)")
        line("Model:                  \(model)")
        line("Device Version:         \(deviceVersion)")
        line("Serial Number:          \(serial)")
        line(String(format: "Standard Version:       %d.%02d", standardVersion / 100, standardVersion % 100))
        line(String(format: "Vendor Extension ID:    0x%08X (%@)",
                    vendorExtId, PtpKnownCameras.vendorExtensionName(vendorExtId) as NSString))
        line(String(format: "Vendor Extension Vers:  %d.%02d", vendorExtVer / 100, vendorExtVer % 100))
        line("Vendor Extension Desc:  \(vendorExtDesc)")
        line(String(format: "Functional Mode:        0x%04X", functionalMode))
        line("")

        line("=== Supported Operations (\(ops.count)) ===")
        for op in ops {
            line(String(format: "  0x%04X  %@", op, PtpKnownCameras.operationName(op) as NSString))
        }
        line("")

        line("=== Supported Events (\(events.count)) ===")
        for ev in events {
            line(String(format: "  0x%04X  %@", ev, PtpKnownCameras.eventName(ev) as NSString))
        }
        line("")

        line("=== Supported Properties (\(propIds.count)) ===")
        for pid in propIds {
            line(String(format: "  0x%04X  %@", pid, PtpKnownCameras.propertyName(pid) as NSString))
        }
        line("")

        line("=== Supported Capture Formats (\(captureFmts.count)) ===")
        for cf in captureFmts { line(String(format: "  0x%04X", cf)) }
        line("")

        line("=== Supported Image Formats (\(imageFmts.count)) ===")
        for f in imageFmts { line(String(format: "  0x%04X", f)) }
        line("")

        return true
    }

    // MARK: - Property descriptors

    private func dumpPropertyDescriptors() {
        line("=== Property Descriptors ===")
        line("")
        if supportedPropIds.isEmpty {
            line("(none reported in GetDeviceInfo)")
            return
        }
        for pid in supportedPropIds {
            dumpOneProperty(pid)
            line("")
        }
    }

    private func dumpOneProperty(_ pid: UInt16) {
        line(String(format: "[0x%04X] %@", pid, PtpKnownCameras.propertyName(pid) as NSString))

        guard let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [UInt32(pid)])) else {
            line("  GetDevicePropDesc transport error")
            return
        }
        let rspCode = transport.responseCode(from: rsp)
        guard rspCode == PTP_RSP_OK else {
            line(String(format: "  GetDevicePropDesc → 0x%04X", rspCode))
            return
        }
        guard let data = inData, data.count >= 5 else {
            line("  GetDevicePropDesc returned no data")
            return
        }

        // Parse the standard PTP form. (Vendor-extended forms like Sony's
        // extra flags byte are deliberately NOT parsed here; this dump is
        // meant to faithfully reflect the standard wire response so the
        // reader can spot vendor irregularities.)
        let raw = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        line("  Raw (\(data.count) bytes): \(raw.prefix(180))\(data.count > 60 ? " ..." : "")")

        let p = PtpPropParser(data)
        _ = p.readU16()                         // propId echo
        guard let dataType = p.readU16(),
              let getSet   = p.readU8() else {
            line("  (header truncated)")
            return
        }
        let defaultValue = p.readNum(ofType: dataType)
        let currentValue = p.readNum(ofType: dataType)
        let formFlag     = p.readU8() ?? 0

        line(String(format: "  DataType:  0x%04X (%@)", dataType, PtpKnownCameras.dataTypeName(dataType) as NSString))
        line(String(format: "  GetSet:    0x%02X (%@)", getSet, getSet == 0 ? "read-only" : "read/write"))
        line("  Default:   \(formatValue(defaultValue, dataType: dataType, propId: UInt32(pid)))")
        line("  Current:   \(formatValue(currentValue, dataType: dataType, propId: UInt32(pid)))")

        switch formFlag {
        case 0x00:
            line("  Form:      none")
        case 0x01:
            let mn = p.readNum(ofType: dataType)
            let mx = p.readNum(ofType: dataType)
            let st = p.readNum(ofType: dataType)
            line("  Form:      Range")
            line("    Min:     \(formatValue(mn, dataType: dataType, propId: UInt32(pid)))")
            line("    Max:     \(formatValue(mx, dataType: dataType, propId: UInt32(pid)))")
            line("    Step:    \(formatValue(st, dataType: dataType, propId: UInt32(pid)))")
        case 0x02:
            guard let count = p.readU16() else {
                line("  Form:      Enum (count truncated)")
                return
            }
            line("  Form:      Enum (\(count) values)")
            var values: [String] = []
            for _ in 0..<count {
                if let v = p.readNum(ofType: dataType) {
                    values.append(formatValue(v, dataType: dataType, propId: UInt32(pid)))
                }
            }
            // One value per line — interpretations make values long enough
            // that 6-per-line wrapping becomes unreadable.
            for v in values { line("    " + v) }
        default:
            line(String(format: "  Form:      unknown (0x%02X)", formFlag))
        }
    }

    // MARK: - Value formatting

    /// Render a value as `<decimal> (0xHEX) [interpretation]`. The
    /// interpretation comes from `formatExtPropRaw` (shared with the menu
    /// formatter), which knows how to decode Sony/Nikon/Canon vendor codes
    /// — Sony 0x80xx WB names, Nikon shutter (num<<16|den), aperture × 100,
    /// EV bias × 0.001, ISO auto sentinels, etc. Only appended when it
    /// differs from the raw numeric — otherwise we'd print "100 (0x0064) [100]".
    private func formatValue(_ n: NSNumber?, dataType: UInt16, propId: UInt32) -> String {
        guard let n = n else { return "(nil)" }
        let raw: String
        switch dataType {
        case 1: raw = String(format: "%d (0x%02X)", n.int8Value, UInt8(bitPattern: n.int8Value))
        case 2: raw = String(format: "%u (0x%02X)", n.uint8Value, n.uint8Value)
        case 3: raw = String(format: "%d (0x%04X)", n.int16Value, UInt16(bitPattern: n.int16Value))
        case 4: raw = String(format: "%u (0x%04X)", n.uint16Value, n.uint16Value)
        case 5: raw = String(format: "%d (0x%08X)", n.int32Value, UInt32(bitPattern: n.int32Value))
        case 6: raw = String(format: "%u (0x%08X)", n.uint32Value, n.uint32Value)
        default: raw = n.description
        }
        let vendor = PtpKnownCameras.vendor(forVid: transport.vendorId)
        let pretty = formatExtPropRaw(n, propId: propId, vendor: vendor)
        // Drop the interpretation when it's identical to the bare decimal
        // (the default fallback path in formatExtPropRaw).
        if pretty == "\(n)" || pretty == n.stringValue { return raw }
        return "\(raw)  → \(pretty)"
    }
}
