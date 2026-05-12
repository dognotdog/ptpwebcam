// UsbPtpTransport.swift
// Synchronous PTP-over-USB transport using IOUSBLib via the UsbPtpBridge ObjC wrapper.
// Runs inside the CMIO extension (user/262) where ICDeviceBrowser is unavailable.
//
// Uses PtpUsbInterface / PtpUsbPipe (IOUSBLib-backed), which bypass the
// IOServiceDEXTEntitlements check that IOUSBHost enforces.

import Foundation
import IOKit

// MARK: - Error

enum UsbPtpError: Error {
    case deviceNotFound
    case openFailed(Error)
    case endpointNotFound(String)
    case bulkOutFailed(Error)
    case bulkInFailed(Error)
    case shortRead(Int)
    case unexpectedContainer(UInt16)
}

// MARK: - PTP Container Constants

private let kPtpContainerCommand:  UInt16 = 0x0001
private let kPtpContainerData:     UInt16 = 0x0002
private let kPtpContainerResponse: UInt16 = 0x0003

// MARK: - UsbPtpTransport

/// Thread-unsafe, synchronous PTP transport over USB bulk endpoints.
/// All calls to sendPtpCommand must come from the same serial queue.
class UsbPtpTransport {

    let vendorId:   UInt16
    let productId:  UInt16
    let deviceName: String

    private let iface:       PtpUsbInterface
    private let bulkOut:     PtpUsbPipe
    private let bulkIn:      PtpUsbPipe
    private(set) var interruptIn: PtpUsbPipe?

    private var txnCounter: UInt32 = 0

    // MARK: - Discovery

    /// Returns IOKit service handles for attached PTP Still Imaging (class 6) USB interfaces.
    /// Caller must release each handle with IOObjectRelease.
    static func findPtpServices() -> [io_service_t] {
        guard let matching = UsbPtpBridge.ptpMatchingDictionary() else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           matching as CFDictionary,
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let svc = IOIteratorNext(iterator), svc != IO_OBJECT_NULL {
            services.append(svc)
        }
        return services
    }

    /// Returns the IOKit service handle for the specific camera matching vid/pid/serial.
    /// Releases all non-matching services. Caller must release the returned handle.
    static func findService(vid: UInt16, pid: UInt16, serial: String) -> io_service_t? {
        let services = findPtpServices()
        var match: io_service_t? = nil
        for svc in services {
            var sVid: UInt16 = 0
            var sPid: UInt16 = 0
            var sSerial: NSString?
            UsbPtpBridge.readVendorID(&sVid, productID: &sPid, productName: nil, serialNumber: &sSerial, fromService: svc)
            if sVid == vid && sPid == pid && (sSerial as String?) == serial {
                match = svc
            } else {
                IOObjectRelease(svc)
            }
        }
        return match
    }

    // MARK: - Init

    init(service: io_service_t) throws {
        // Read VID/PID/name from IOKit registry.
        var vid: UInt16 = 0
        var pid: UInt16 = 0
        var name: NSString?
        var serial: NSString?
        UsbPtpBridge.readVendorID(&vid, productID: &pid, productName: &name, serialNumber: &serial, fromService: service)
        vendorId   = vid
        productId  = pid
        deviceName = (name as String?) ?? "PTP Camera"

        // Open the PTP USB interface via IOUSBLib (avoids DEXT entitlement check).
        let opened: PtpUsbInterface
        do {
            opened = try PtpUsbInterface(service: service)
        } catch {
            throw UsbPtpError.openFailed(error)
        }
        iface = opened

        // ── Endpoint discovery ───────────────────────────────────────────────
        // PTP/MTP Still Imaging interface has:
        //   bulk-OUT  (bmAttributes & 3 = 2, address bit7 = 0)
        //   bulk-IN   (bmAttributes & 3 = 2, address bit7 = 1)
        //   interrupt-IN (bmAttributes & 3 = 3, address bit7 = 1)

        var foundOut: PtpUsbPipe?
        var foundIn:  PtpUsbPipe?
        var foundInt: PtpUsbPipe?

        for pipe in iface.pipes {
            let isIn    = (pipe.address & 0x80) != 0
            let isBulk  = (pipe.bmAttributes & 0x03) == 0x02
            let isIntr  = (pipe.bmAttributes & 0x03) == 0x03

            if !isIn && isBulk  && foundOut == nil { foundOut = pipe }
            if  isIn && isBulk  && foundIn  == nil { foundIn  = pipe }
            if  isIn && isIntr  && foundInt == nil { foundInt = pipe }
        }

        guard let bo = foundOut, let bi = foundIn else {
            iface.close()
            throw UsbPtpError.endpointNotFound(
                "bulk-OUT=\(foundOut != nil) bulk-IN=\(foundIn != nil)")
        }
        bulkOut     = bo
        bulkIn      = bi
        interruptIn = foundInt

        // Log discovered pipes for diagnostics.
        for p in iface.pipes {
            PtpWebcamCameraExtensionProviderSource.log(
                "USB pipe idx=\(p.pipeIndex) addr=0x\(String(p.address, radix:16)) bmAttr=0x\(String(p.bmAttributes, radix:16))")
        }
    }

    /// Issue ClearPipeStall on all bulk/interrupt pipes.
    func clearStalls() {
        for pipe in iface.pipes {
            _ = try? pipe.clearStall()
        }
    }

    // MARK: - Close

    func close() {
        iface.close()
    }

    // MARK: - Command Dispatch

    /// Synchronous PTP command dispatch.
    /// Sends a command container (and optionally an outgoing data container) over bulk-OUT,
    /// then reads back any incoming data container and the response container from bulk-IN.
    /// Returns (inData, response) where inData is nil for operations with no data phase.
    func sendPtpCommand(_ command: Data, outData: Data? = nil) throws -> (inData: Data?, response: Data) {

        // ── 1. Send command container ────────────────────────────────────────
        // ObjC NSError** → Swift throws; `error:` label stripped, BOOL return dropped.
        let cmdBuf = NSMutableData(data: command)
        do {
            try bulkOut.send(cmdBuf, bytesTransferred: nil, timeout: 5.0)
        } catch {
            throw UsbPtpError.bulkOutFailed(error)
        }

        // ── 2. Optionally send data container ────────────────────────────────
        if let outData = outData {
            let txn  = command.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
            let code = command.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
            var dc = Data()
            dc.appendLE(UInt32(12 + outData.count))
            dc.appendLE(kPtpContainerData)
            dc.appendLE(code)
            dc.appendLE(txn)
            dc.append(outData)
            let dataBuf = NSMutableData(data: dc)
            do {
                try bulkOut.send(dataBuf, bytesTransferred: nil, timeout: 5.0)
            } catch {
                throw UsbPtpError.bulkOutFailed(error)
            }
        }

        // ── 3. Read first response packet ────────────────────────────────────
        let first = try readBulkIn()
        guard first.count >= 6 else { throw UsbPtpError.shortRead(first.count) }
        let containerType = first.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }

        switch containerType {
        case kPtpContainerData:
            let resp = try readBulkIn()
            return (inData: Data(first.dropFirst(12)), response: resp)
        case kPtpContainerResponse:
            return (inData: nil, response: first)
        default:
            throw UsbPtpError.unexpectedContainer(containerType)
        }
    }

    private func readBulkIn() throws -> Data {
        // 4 MB buffer — large enough for any live view frame.
        let buf = NSMutableData(length: 4 * 1024 * 1024)!
        var received: UInt = 0
        do {
            try bulkIn.receive(into: buf, bytesReceived: &received, timeout: 5.0)
        } catch {
            throw UsbPtpError.bulkInFailed(error)
        }
        guard received >= 12 else { throw UsbPtpError.shortRead(Int(received)) }
        return Data(bytes: buf.bytes, count: Int(received))
    }

    // MARK: - Command Building

    func buildCommand(code: UInt16, parameters: [UInt32] = []) -> Data {
        txnCounter += 1
        var d = Data()
        d.appendLE(UInt32(12 + parameters.count * 4))
        d.appendLE(kPtpContainerCommand)
        d.appendLE(code)
        d.appendLE(txnCounter)
        for p in parameters { d.appendLE(p) }
        return d
    }

    func responseCode(from response: Data) -> UInt16 {
        guard response.count >= 8 else { return 0 }
        return response.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
    }

    /// Read a single PTP event packet from the interrupt-IN pipe.
    /// Returns nil if there is no interrupt pipe, the read times out, or fewer than 12 bytes arrive.
    func readInterruptEvent(timeout: TimeInterval) -> Data? {
        guard let pipe = interruptIn else { return nil }
        let buf = NSMutableData(length: 64)!
        var received: UInt = 0
        guard (try? pipe.receive(into: buf, bytesReceived: &received, timeout: timeout)) != nil,
              received >= 12 else { return nil }
        return Data(bytes: buf.bytes, count: Int(received))
    }

    /// Attempt a single bulk-IN read to drain data the camera is sending.
    /// timeout: how long to wait if the pipe is empty (use short value like 0.05 s).
    /// Ignores errors; returns bytes received.
    func drainBulkIn(timeout: TimeInterval) -> UInt {
        let buf = NSMutableData(length: 4 * 1024 * 1024)!
        var received: UInt = 0
        let _ = try? bulkIn.receive(into: buf, bytesReceived: &received, timeout: timeout)
        return received
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
