//
//  PtpWebcamCameraExtensionProvider.swift
//  PtpWebcamCameraExtension
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 Doemoetoer Gulyas. All rights reserved.
//

import Foundation
import CoreMediaIO
import IOKit
import IOKit.audio
import CoreVideo
import CoreGraphics
import ImageIO
import os.log

let kWhiteStripeHeight: Int = 10
let kFrameRate: Int = 30

// MARK: -

class PtpWebcamCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

	private(set) var device: CMIOExtensionDevice!
	let cameraId: String

	private var _streamSource: PtpWebcamCameraExtensionStreamSource!
	private var _streamingCounter: UInt32 = 0
	private var _timer: DispatchSourceTimer?

	private let _timerQueue = DispatchQueue(label: "timerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))

	private var _videoDescription: CMFormatDescription!

	private var _whiteStripeStartRow: UInt32 = 0
	private var _whiteStripeIsAscending: Bool = false
	private var _stripePixelsPerStep: Int = 1
	private var _stripeFrameInterval: Int = 1
	private var _stripeFrameCount: Int = 0

	let isDemo: Bool

	var onStreamingStarted: (() -> Void)?
	var onStreamingStopped: (() -> Void)?

	func applyStripeSpeed(_ speed: String) {
		switch speed {
		case "slow":  _stripePixelsPerStep = 1; _stripeFrameInterval = 3
		case "fast":  _stripePixelsPerStep = 3; _stripeFrameInterval = 1
		default:      _stripePixelsPerStep = 1; _stripeFrameInterval = 1
		}
	}

	init(localizedName: String, cameraId: String, isDemo: Bool = false) {
		self.isDemo = isDemo

		self.cameraId = cameraId
		super.init()

		let deviceID = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

		let dims = CMVideoDimensions(width: 1920, height: 1080)
		CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)

		let videoStreamFormat = CMIOExtensionStreamFormat(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)

		let videoID = UUID()
		_streamSource = PtpWebcamCameraExtensionStreamSource(localizedName: "\(localizedName) Video", streamID: videoID, streamFormat: videoStreamFormat, device: device)
		do {
			try device.addStream(_streamSource.stream)
		} catch let error {
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}
	}

	var availableProperties: Set<CMIOExtensionProperty> {
		return [.deviceTransportType, .deviceModel]
	}

	func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
		let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
		if properties.contains(.deviceTransportType) {
			deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
		}
		if properties.contains(.deviceModel) {
			deviceProperties.model = "PtpWebcam"
		}
		return deviceProperties
	}

	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
	}

	func startStreaming() {
		_streamingCounter += 1
		if _streamingCounter == 1 {
			onStreamingStarted?()
			if isDemo { startDemoTimer() }
		}
	}

	func stopStreaming() {
		if _streamingCounter > 1 {
			_streamingCounter -= 1
		} else {
			_streamingCounter = 0
			onStreamingStopped?()
			_timer?.cancel()
			_timer = nil
		}
	}

	// Send a live-view frame to CMIO.
	// The format description is derived from the pixel buffer itself so any camera
	// resolution is accepted without reconfiguring a pool or cached descriptor.
	func sendLiveViewFrame(_ pixelBuffer: CVPixelBuffer) {
		guard _streamingCounter > 0 else { return }

		var fmtDesc: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmtDesc)
		guard let fmtDesc = fmtDesc else { return }

		var timingInfo = CMSampleTimingInfo()
		timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
		var sbuf: CMSampleBuffer?
		let err = CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
			makeDataReadyCallback: nil, refcon: nil, formatDescription: fmtDesc,
			sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
		if err == 0, let sbuf = sbuf {
			_streamSource.stream.send(sbuf, discontinuity: [],
				hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
		}
	}

	private func startDemoTimer() {
		_timer?.cancel()
		let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
		timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(2))
		timer.setEventHandler { [weak self] in
			self?.sendDemoFrame()
		}
		timer.resume()
		_timer = timer
	}

	private func sendDemoFrame() {
		var err: OSStatus = 0
		var pixelBuffer: CVPixelBuffer?
		let dims = CMVideoFormatDescriptionGetDimensions(_videoDescription)
		CVPixelBufferCreate(kCFAllocatorDefault, Int(dims.width), Int(dims.height),
			kCVPixelFormatType_32BGRA,
			[kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
			&pixelBuffer)
		guard err == 0, let pixelBuffer = pixelBuffer else { return }

		CVPixelBufferLockBaseAddress(pixelBuffer, [])

		var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
		memset(bufferPtr, 0, rowBytes * height)

		let whiteStripeStartRow = _whiteStripeStartRow
		_stripeFrameCount += 1
		if _stripeFrameCount >= _stripeFrameInterval {
			_stripeFrameCount = 0
			for _ in 0..<_stripePixelsPerStep {
				if _whiteStripeIsAscending {
					_whiteStripeStartRow = _whiteStripeStartRow > 0 ? _whiteStripeStartRow - 1 : 0
					_whiteStripeIsAscending = _whiteStripeStartRow > 0
				} else {
					_whiteStripeStartRow += 1
					_whiteStripeIsAscending = _whiteStripeStartRow >= UInt32(height - kWhiteStripeHeight)
				}
			}
		}
		bufferPtr += rowBytes * Int(whiteStripeStartRow)
		for _ in 0..<kWhiteStripeHeight {
			for _ in 0..<width {
				var white: UInt32 = 0xFFFFFFFF
				memcpy(bufferPtr, &white, MemoryLayout.size(ofValue: white))
				bufferPtr += MemoryLayout.size(ofValue: white)
			}
		}

		CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

		var fmtDesc: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmtDesc)
		guard let fmtDesc = fmtDesc else { return }
		var sbuf: CMSampleBuffer?
		var timingInfo = CMSampleTimingInfo()
		timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
		err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmtDesc, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
		if err == 0, let sbuf = sbuf {
			_streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
		}
	}
}

// MARK: -

class PtpWebcamCameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

	private(set) var stream: CMIOExtensionStream!

	let device: CMIOExtensionDevice

	private let _streamFormat: CMIOExtensionStreamFormat

	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {

		self.device = device
		self._streamFormat = streamFormat
		super.init()
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
	}

	var formats: [CMIOExtensionStreamFormat] {
		return [_streamFormat]
	}

	var activeFormatIndex: Int = 0 {
		didSet {
			if activeFormatIndex >= 1 {
				os_log(.error, "Invalid index")
			}
		}
	}

	var availableProperties: Set<CMIOExtensionProperty> {
		return [.streamActiveFormatIndex, .streamFrameDuration]
	}

	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		if properties.contains(.streamActiveFormatIndex) {
			streamProperties.activeFormatIndex = 0
		}
		if properties.contains(.streamFrameDuration) {
			let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			streamProperties.frameDuration = frameDuration
		}
		return streamProperties
	}

	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
		if let activeFormatIndex = streamProperties.activeFormatIndex {
			self.activeFormatIndex = activeFormatIndex
		}
	}

	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
		return true
	}

	func startStream() throws {
		guard let deviceSource = device.source as? PtpWebcamCameraExtensionDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		deviceSource.startStreaming()
	}

	func stopStream() throws {
		guard let deviceSource = device.source as? PtpWebcamCameraExtensionDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		deviceSource.stopStreaming()
	}
}

// MARK: -

class PtpWebcamCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

	private(set) var provider: CMIOExtensionProvider!

	private let logger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.CameraExtension", category: "Provider")
	private var deviceSources: [String: PtpWebcamCameraExtensionDeviceSource] = [:]

	private static let extLogger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.CameraExtension", category: "ExtLog")

	static func log(_ msg: String) {
		extLogger.fault("\(msg, privacy: .public)")
	}

	/// Wrap `notify_register_check` so silent failures (e.g. kernel notify-token
	/// limit reached, ~1024 per process) are at least visible in the log. A
	/// failed registration returns token 0; downstream slot reads/writes then
	/// silently no-op, which is hard to debug.
	@discardableResult
	static func registerCheckToken(_ name: String, label: String) -> Int32 {
		var token: Int32 = 0
		let status = darwin_notify_register_check(name, &token)
		if status != 0 {
			log("notify_register_check failed status=\(status) name=\(name) (\(label))")
		}
		return token
	}

	@discardableResult
	static func registerDispatchToken(_ name: String, queue: DispatchQueue, label: String,
	                                  handler: @escaping @convention(block) (Int32) -> Void) -> Int32 {
		var token: Int32 = 0
		let status = darwin_notify_register_dispatch(name, &token, queue, handler)
		if status != 0 {
			log("notify_register_dispatch failed status=\(status) name=\(name) (\(label))")
		}
		return token
	}

	// USB cameras keyed by cameraId — opened on claim.
	private var usbCameras: [String: any UsbCameraProtocol] = [:]

	// Camera IDs that received a streaming-start request before the USB camera was ready.
	private var pendingLiveViewStart: Set<String> = []

	// Discovered camera properties keyed by cameraId, then by propertyId.
	private var cameraProperties: [String: [UInt32: UsbCameraProperty]] = [:]

	// VID, PID, serial keyed by cameraId — populated at IOKit attach time.
	private var cameraIdentity: [String: (vid: UInt16, pid: UInt16, serial: String)] = [:]

	// Darwin notify tokens for property state slots (extension → agent).
	private var propSlotTokens: [Int32] = []
	// Darwin notify tokens for PTP-dump device-list slots (extension → app).
	private var dumpDevicesSlotTokens: [Int32] = []
	// Darwin notify tokens for PTP-dump text slots (extension → app).
	private var dumpTextSlotTokens: [Int32] = []
	// Darwin notify tokens for live-view-failure text slots (extension → agent).
	private var lvFailSlotTokens: [Int32] = []
	private var usbBlockedSlotTokens: [Int32] = []
	// Serialized dump queue so we never run two dumps (potentially fighting
	// over the same USB endpoints) at once.
	private let dumpQueue = DispatchQueue(label: "org.ptpwebcam.dump", qos: .userInitiated)
	// Serializes writes to the shared property-state slots. Multiple back-to-back
	// publishes (e.g. both cameras announcing themselves at extension startup)
	// would otherwise overwrite each other in the slots — the kernel coalesces
	// the `darwin_notify_post` calls and the agent only ever sees the LAST data.
	private let publishQueue = DispatchQueue(label: "org.ptpwebcam.publish", qos: .userInteractive)
	// Per-camera claim tokens: array of (slotToken, notifyToken) keyed by cameraId.
	// We may register more than one suffix per camera (initially the USB
	// descriptor serial, then again with the PTP serial once GetDeviceInfo
	// returns) so commands reach us regardless of which suffix the agent uses.
	private var claimTokens: [String: [(slot: Int32, notify: Int32)]] = [:]
	// Per-camera property command tokens (agent → extension). Same multi-suffix
	// approach as claimTokens.
	private var propCmdTokens: [String: [(slot: Int32, notify: Int32)]] = [:]
	// Suffixes already registered for this camera, to dedupe re-registration.
	private var registeredSuffixes: [String: Set<String>] = [:]

	// IOKit USB device detection (replaces ICDeviceBrowser / Darwin notify camera state).
	private var ioNotificationPort: IONotificationPortRef?
	private var ioAddedIterator:   io_iterator_t = IO_OBJECT_NULL
	private var ioRemovedIterator: io_iterator_t = IO_OBJECT_NULL

	init(clientQueue: DispatchQueue?) {

		super.init()

		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

		// Register property state slots (extension → agent).
		propSlotTokens = (0..<kDarwinPropertySlotCount).map { i in
			let name = kDarwinPropertySlotPrefix + "\(i)"
			return Self.registerCheckToken(name, label: "propSlot[\(i)]")
		}

		// Register dump-related slots (extension → app).
		dumpDevicesSlotTokens = (0..<kDarwinPtpDumpDevicesSlotCount).map { i in
			Self.registerCheckToken(kDarwinPtpDumpDevicesSlotPrefix + "\(i)",
			                        label: "dumpDevSlot[\(i)]")
		}
		dumpTextSlotTokens = (0..<kDarwinPtpDumpTextSlotCount).map { i in
			Self.registerCheckToken(kDarwinPtpDumpTextSlotPrefix + "\(i)",
			                        label: "dumpTextSlot[\(i)]")
		}
		lvFailSlotTokens = (0..<kDarwinLiveViewFailedSlotCount).map { i in
			Self.registerCheckToken(kDarwinLiveViewFailedSlotPrefix + "\(i)",
			                        label: "lvFailSlot[\(i)]")
		}
		usbBlockedSlotTokens = (0..<kDarwinUsbBlockedSlotCount).map { i in
			Self.registerCheckToken(kDarwinUsbBlockedSlotPrefix + "\(i)",
			                        label: "usbBlockedSlot[\(i)]")
		}

		// Per-camera claim and property-command channels are registered in cameraConnected.

		// Republish handler: when the agent restarts (launchd respawn, app
		// reinstall, etc.) it loses every Darwin notify slot it was tracking.
		// Posts kDarwinCameraStateRepublish on startup so we can re-emit
		// cameraConnected + propertyState for every known camera, otherwise
		// the menu stays blank until the user replugs.
		_ = Self.registerDispatchToken(kDarwinCameraStateRepublish, queue: .main,
		                               label: "republish") { [weak self] _ in
			self?.republishAllCameraState()
		}

		// App requests current PTP-class USB device list.
		_ = Self.registerDispatchToken(kDarwinPtpDumpDevicesRequest, queue: .main,
		                               label: "dumpDevicesRequest") { [weak self] _ in
			self?.publishDumpDevicesList()
		}
		// App requests a property dump for a specific device.
		let dumpCmdSlotToken = Self.registerCheckToken(kDarwinPtpDumpCmdSlot,
		                                               label: "dumpCmdSlot")
		_ = Self.registerDispatchToken(kDarwinPtpDumpCmd, queue: .main,
		                               label: "dumpCmd") { [weak self] _ in
			var value: UInt64 = 0
			darwin_notify_get_state(dumpCmdSlotToken, &value)
			let locationID = UInt32(value & 0xFFFFFFFF)
			self?.handleDumpCommand(locationID: locationID)
		}

		let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
		PtpWebcamCameraExtensionProviderSource.log("PtpWebcam extension started build=\(buildVersion)")

		// Defer IOKit camera detection until after CMIOExtensionProvider.startService()
		// and CFRunLoopRun() are both running.  Calling addDevice() synchronously from
		// init() (before the run loop is up) can deadlock inside CMIOExtensionProvider.
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			PtpWebcamCameraExtensionProviderSource.log("PtpWebcam extension run loop active build=\(buildVersion)")
			self.setupIoKitCameraDetection()
		}
	}

	// MARK: - Property State (extension → agent)

	private func publishPropertyState(cameraId: String) {
		guard let props = cameraProperties[cameraId], !props.isEmpty else { return }

		var propsList: [[String: Any]] = []
		for (_, prop) in props {
			var entry: [String: Any] = [
				"i": prop.propertyId,
				"dt": prop.dataType,
				"w": prop.writable ? 1 : 0,
				"v": prop.value,
			]
			// Cap at 128 values to keep the JSON bounded — Canon's shutter
			// list has 53 entries and 32 was truncating it mid-table (cutting
			// off 1/100 and faster). 128 covers every camera we've seen and
			// still fits comfortably in the 16 KB property-state slot pages.
			if prop.writable, let e = prop.enumValues { entry["e"] = Array(e.prefix(128)) }
			if let rmin = prop.rangeMin, let rmax = prop.rangeMax, let rstep = prop.rangeStep {
				entry["r"] = ["min": rmin, "max": rmax, "step": rstep]
			}
			// Sony step-flags: `inc` = property is set via SetPropStep (the
			// agent shows +/- steppers instead of an enum picker), `btn` =
			// momentary button property. Only emitted when set, to keep the
			// JSON small for the vast majority of non-Sony properties.
			if prop.incremental { entry["inc"] = 1 }
			if prop.isButton    { entry["btn"] = 1 }
			propsList.append(entry)
		}
		let cameraName = deviceSources[cameraId]?.device.localizedName ?? cameraId
		let identity = cameraIdentity[cameraId]
		let dict: [String: Any] = ["id": cameraId, "name": cameraName,
		                           "vid": identity?.vid ?? 0, "pid": identity?.pid ?? 0,
		                           "serial": identity?.serial ?? "",
		                           "props": propsList]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
		writeJsonToPropertySlots(jsonData)
		PtpWebcamCameraExtensionProviderSource.log("publishPropertyState: \(jsonData.count)B for \(cameraId)")
	}

	private func publishCameraConnected(cameraId: String) {
		guard let identity = cameraIdentity[cameraId],
		      let name = deviceSources[cameraId]?.device.localizedName else { return }
		let dict: [String: Any] = ["id": cameraId, "name": name,
		                           "vid": identity.vid, "pid": identity.pid,
		                           "serial": identity.serial,
		                           "connected": true, "props": []]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
		writeJsonToPropertySlots(jsonData)
		PtpWebcamCameraExtensionProviderSource.log("publishCameraConnected: \(cameraId) \(name)")
	}

	/// Re-emit cameraConnected and (if known) propertyState for every camera
	/// we currently have. Triggered by the agent posting
	/// kDarwinCameraStateRepublish on startup — Darwin notify posts don't
	/// replay for late subscribers, so a freshly-respawned agent would
	/// otherwise have an empty menu until the user replugs the camera.
	private func republishAllCameraState() {
		PtpWebcamCameraExtensionProviderSource.log("republishAllCameraState: \(cameraIdentity.count) cameras")
		for cameraId in cameraIdentity.keys {
			publishCameraConnected(cameraId: cameraId)
			if cameraProperties[cameraId]?.isEmpty == false {
				publishPropertyState(cameraId: cameraId)
			}
		}
	}

	/// Register per-camera claim + property-command channels under the
	/// `vid.pid.crc(serial)` suffix. Safe to call multiple times for the same
	/// camera with different serials — subsequent calls add additional listener
	/// tokens so commands match whichever suffix the agent computed.
	private func registerPerCameraNotifyChannels(cameraId: String, vid: UInt16, pid: UInt16, serial: String) {
		let crc = crc32OfString(serial) & 0x00FFFFFF
		let suffix = String(format: "%04x.%04x.%06x", vid, pid, crc)

		if registeredSuffixes[cameraId, default: []].contains(suffix) { return }
		registeredSuffixes[cameraId, default: []].insert(suffix)

		let slotToken = Self.registerCheckToken(kDarwinClaimCameraSlot + "." + suffix,
		                                        label: "claim slot \(cameraId) [\(suffix)]")
		let notifyToken = Self.registerDispatchToken(kDarwinClaimCamera + "." + suffix, queue: .main,
		                                             label: "claim notify \(cameraId) [\(suffix)]") { [weak self] _ in
			self?.handleClaimCommand(cameraId: cameraId, slotToken: slotToken)
		}
		claimTokens[cameraId, default: []].append((slot: slotToken, notify: notifyToken))

		let propSlotToken = Self.registerCheckToken(kDarwinPropertyCmdSlot + "." + suffix,
		                                            label: "propcmd slot \(cameraId) [\(suffix)]")
		let propNotifyToken = Self.registerDispatchToken(kDarwinCameraPropertyCmd + "." + suffix, queue: .main,
		                                                 label: "propcmd notify \(cameraId) [\(suffix)]") { [weak self] _ in
			self?.handlePropertyCommand(cameraId: cameraId, slotToken: propSlotToken)
		}
		propCmdTokens[cameraId, default: []].append((slot: propSlotToken, notify: propNotifyToken))

		PtpWebcamCameraExtensionProviderSource.log("registered per-camera notify channels for \(cameraId) suffix=\(suffix)")
	}

	private func publishCameraRemoved(cameraId: String) {
		let dict: [String: Any] = ["id": cameraId, "disconnected": true, "props": []]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
		writeJsonToPropertySlots(jsonData)
		PtpWebcamCameraExtensionProviderSource.log("publishCameraRemoved: \(cameraId)")
	}

	private func writeJsonToPropertySlots(_ jsonData: Data) {
		// Hand off to the publish queue so consecutive publishes don't overwrite
		// each other's slots before the agent's notification handler can read.
		publishQueue.async { [weak self] in
			guard let self else { return }
			self.publishBytesViaSlotChain(jsonData,
			                              tokens: self.propSlotTokens,
			                              notificationName: kDarwinCameraPropertyState)
		}
	}

	/// Per-page delay between `darwin_notify_post` calls. Gives the agent's
	/// `.main`-queue notification handler time to drain each post — without
	/// this, the kernel coalesces back-to-back posts and slot contents get
	/// overwritten before the agent reads them. ~60 ms is empirically enough
	/// for cold-start contention (two cameras announcing simultaneously).
	private static let publishPostDelay: TimeInterval = 0.06

	/// Generic slot-chain publisher used by property-state, dump-devices-list,
	/// and dump-text channels. Same multi-page protocol everywhere:
	///   slot 0       : header = (totalLength << 32) | (pageIndex << 16) | pageCount
	///   slots 1..N-2 : payload, 8 bytes per slot, little-endian byte packing
	///   slot N-1     : additive byte-sum checksum for this page's payload
	/// Posts `notificationName` once per page; receiver reassembles pages by
	/// stitching by `pageIndex` until it has `totalLength` bytes.
	fileprivate func publishBytesViaSlotChain(_ data: Data,
	                                          tokens: [Int32],
	                                          notificationName: String) {
		let slotCount = tokens.count
		guard slotCount >= 3 else { return }
		let pageDataSlots = slotCount - 2
		let pageSize = pageDataSlots * 8
		let totalLength = data.count
		let pageCount = max(1, (totalLength + pageSize - 1) / pageSize)
		let checksumSlot = slotCount - 1

		for pageIndex in 0..<pageCount {
			let pageOffset = pageIndex * pageSize
			let pageEnd = min(pageOffset + pageSize, totalLength)
			let pageLength = pageEnd - pageOffset

			let header = (UInt64(totalLength) << 32) | (UInt64(pageIndex) << 16) | UInt64(pageCount)
			darwin_notify_set_state(tokens[0], header)

			for i in 0..<((pageLength + 7) / 8) {
				let chunkOffset = pageOffset + i * 8
				let chunkSize = min(8, totalLength - chunkOffset)
				var value: UInt64 = 0
				_ = data.withUnsafeBytes { ptr in
					memcpy(&value, ptr.baseAddress! + chunkOffset, chunkSize)
				}
				darwin_notify_set_state(tokens[i + 1], value)
			}

			var checksum: UInt32 = 0
			for byte in data[pageOffset..<pageEnd] { checksum = checksum &+ UInt32(byte) }
			darwin_notify_set_state(tokens[checksumSlot], UInt64(checksum))

			darwin_notify_post(notificationName)
			Thread.sleep(forTimeInterval: Self.publishPostDelay)
		}
	}

	// MARK: - Property Command (agent → extension)

	private func handlePropertyCommand(cameraId: String, slotToken: Int32) {
		var packed: UInt64 = 0
		darwin_notify_get_state(slotToken, &packed)
		let cmd    = UInt8((packed >> 56) & 0xFF)
		let propId = UInt32((packed >> 32) & 0xFFFF)
		let value  = UInt32(packed & 0xFFFFFFFF)

		guard let camera = usbCameras[cameraId] else {
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand[\(cameraId)]: camera not claimed")
			return
		}

		switch cmd {
		case 3:  // SET_PROP
			guard let dataType = cameraProperties[cameraId]?[propId]?.dataType else {
				PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand[\(cameraId)]: unknown propId=0x\(String(propId, radix:16))")
				return
			}
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: SET_PROP 0x\(String(propId, radix:16))=\(value) on \(cameraId)")
			camera.setProperty(propId: propId, value: value, dataType: dataType)
		case 4:  // TRIGGER_AF
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: TRIGGER_AF on \(cameraId)")
			camera.triggerAutofocus()
		default:
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand[\(cameraId)]: unknown cmd=\(cmd)")
		}
	}

	private func handleClaimCommand(cameraId: String, slotToken: Int32) {
		var cmd: UInt64 = 0
		darwin_notify_get_state(slotToken, &cmd)

		if cmd == 1 {
			guard usbCameras[cameraId] == nil,
				  let deviceSource = deviceSources[cameraId],
				  let identity = cameraIdentity[cameraId] else { return }
			PtpWebcamCameraExtensionProviderSource.log("handleClaimCommand: claiming \(cameraId)")
			let camVid = identity.vid; let camPid = identity.pid; let camSerial = identity.serial
			DispatchQueue.global(qos: .userInteractive).async { [weak self] in
				self?.openUsbCamera(cameraId: cameraId, deviceSource: deviceSource,
				                    vid: camVid, pid: camPid, serial: camSerial)
			}
		} else if cmd == 2 {
			PtpWebcamCameraExtensionProviderSource.log("handleClaimCommand: releasing \(cameraId)")
			usbCameras.removeValue(forKey: cameraId)?.close()
			cameraProperties.removeValue(forKey: cameraId)
			publishCameraConnected(cameraId: cameraId)
		}
	}

	private func crc32OfString(_ s: String) -> UInt32 {
		// Simple polynomial CRC-32 (IEEE 802.3).
		var crc: UInt32 = 0xFFFFFFFF
		for byte in s.utf8 {
			crc ^= UInt32(byte)
			for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1)) }
		}
		return crc ^ 0xFFFFFFFF
	}

	// MARK: - IOKit camera detection

	private func setupIoKitCameraDetection() {
		guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
			PtpWebcamCameraExtensionProviderSource.log("setupIoKitCameraDetection: IONotificationPortCreate failed")
			return
		}
		ioNotificationPort = port
		IONotificationPortSetDispatchQueue(port, .main)

		// Attach notifications —— drain the iterator to get the initial snapshot.
		if let dict = UsbPtpBridge.ptpMatchingDictionary() {
			let ctx = Unmanaged.passUnretained(self).toOpaque()
			IOServiceAddMatchingNotification(
				port, kIOFirstMatchNotification, dict as CFDictionary,
				{ ctx, iter in
					Unmanaged<PtpWebcamCameraExtensionProviderSource>
						.fromOpaque(ctx!).takeUnretainedValue().ioServiceAdded(iter)
				},
				ctx, &ioAddedIterator)
			ioServiceAdded(ioAddedIterator)  // drain initial snapshot
		}

		// Detach notifications.
		if let dict = UsbPtpBridge.ptpMatchingDictionary() {
			let ctx = Unmanaged.passUnretained(self).toOpaque()
			IOServiceAddMatchingNotification(
				port, kIOTerminatedNotification, dict as CFDictionary,
				{ ctx, iter in
					Unmanaged<PtpWebcamCameraExtensionProviderSource>
						.fromOpaque(ctx!).takeUnretainedValue().ioServiceRemoved(iter)
				},
				ctx, &ioRemovedIterator)
			ioServiceRemoved(ioRemovedIterator)  // drain any already-terminated
		}

		PtpWebcamCameraExtensionProviderSource.log("setupIoKitCameraDetection: watching for PTP interfaces")
	}

	private func ioServiceAdded(_ iterator: io_iterator_t) {
		while case let svc = IOIteratorNext(iterator), svc != IO_OBJECT_NULL {
			defer { IOObjectRelease(svc) }

			var entryId: UInt64 = 0
			IORegistryEntryGetRegistryEntryID(svc, &entryId)
			let cameraId = String(format: "usb-%016llx", entryId)

			var vid: UInt16 = 0; var pid: UInt16 = 0; var nsName: NSString?; var nsSerial: NSString?
			UsbPtpBridge.readVendorID(&vid, productID: &pid, productName: &nsName, serialNumber: &nsSerial, fromService: svc)
			let name   = (nsName   as String?) ?? "PTP Camera"
			let serial = (nsSerial as String?) ?? ""

			PtpWebcamCameraExtensionProviderSource.log(
				"IOKit: attached vid=0x\(String(vid, radix:16)) pid=0x\(String(pid, radix:16)) serial='\(serial)' \"\(name)\" id=\(cameraId)")
			cameraConnected(cameraId, info: ["name": name, "vid": NSNumber(value: vid),
			                                 "pid": NSNumber(value: pid), "serial": serial] as NSDictionary)
		}
	}

	private func ioServiceRemoved(_ iterator: io_iterator_t) {
		while case let svc = IOIteratorNext(iterator), svc != IO_OBJECT_NULL {
			defer { IOObjectRelease(svc) }

			var entryId: UInt64 = 0
			IORegistryEntryGetRegistryEntryID(svc, &entryId)
			let cameraId = String(format: "usb-%016llx", entryId)

			PtpWebcamCameraExtensionProviderSource.log("IOKit: removed id=\(cameraId)")
			cameraDisconnected(cameraId)
		}
	}

	// MARK: - USB Camera (direct PTP over IOUSBHost)

	/// Opens USB transport + PTP session for a newly connected camera.
	/// Called at camera connect time on a background queue.
	/// All dict mutations are dispatched back to main to avoid data races.
	private func openUsbCamera(cameraId: String, deviceSource: PtpWebcamCameraExtensionDeviceSource,
	                           vid: UInt16, pid: UInt16, serial: String) {
		// USB access strategy is gated by the bridge's
		// `PTPWEBCAM_USB_OPEN_MODE` compile-time flag — see
		// UsbPtpBridge.m for the three modes (PLAIN / SEIZE / KILL).
		// The agent kill is fired only in KILL mode; SEIZE relies on
		// the bridge's IOUSBHost seize pass instead, and PLAIN
		// intentionally does nothing so a busy device fails fast and
		// exercises the "camera busy — held by X" diagnostic UI.
		PtpWebcamCameraExtensionProviderSource.log(
			"openUsbCamera: mode = \(UsbPtpBridge.usbOpenModeDescription())")
		if UsbPtpBridge.usesAgentKill() {
			darwin_notify_post(kDarwinNeedUsbAccess)
		}

		var transport: UsbPtpTransport?
		var lastError: Error?
		for attempt in 1...10 {
			Thread.sleep(forTimeInterval: 0.3)
			guard let svc = UsbPtpTransport.findService(vid: vid, pid: pid, serial: serial) else {
				if attempt == 1 { PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: no matching PTP service yet") }
				continue
			}
			do {
				transport = try UsbPtpTransport(service: svc)
				IOObjectRelease(svc)
				PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: interface opened on attempt \(attempt)")
				break
			} catch {
				IOObjectRelease(svc)
				lastError = error
				if attempt == 1 || attempt % 3 == 0 {
					PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: attempt \(attempt)/10 failed: \(error)")
				}
			}
		}

		guard let t = transport else {
			PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: all attempts failed: \(String(describing: lastError))")
			// If the failure was specifically "device held by another
			// userspace driver" (kIOReturnExclusiveAccess = 0xe00002c5),
			// signal the agent so it can identify the culprit app and
			// surface an actionable menu item. lastError comes wrapped as
			// `UsbPtpError.openFailed(inner)` — unwrap to get the real
			// IOUSBErrorDomain NSError.
			let innerError: NSError? = {
				if let usbErr = lastError as? UsbPtpError {
					if case let .openFailed(inner) = usbErr {
						return inner as NSError
					}
				}
				return lastError as NSError?
			}()
			if let nsErr = innerError,
			   nsErr.domain == "IOUSBErrorDomain",
			   IOReturn(Int32(truncatingIfNeeded: nsErr.code)) == kIOReturnExclusiveAccess {
				PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: kIOReturnExclusiveAccess — publishing blocked diagnostic")
				publishUsbBlocked(cameraId: cameraId)
			}
			return
		}

		guard let camera = UsbCameraRegistry.makeCamera(transport: t) else {
			PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: unsupported vendor 0x\(String(t.vendorId, radix:16)) — closing transport")
			t.close()
			return
		}
		camera.onJpegFrame = { [weak deviceSource] jpegData in
			guard let ds = deviceSource else { return }
			autoreleasepool {
				if let pb = jpegIntoPixelBuffer(jpegData) {
					ds.sendLiveViewFrame(pb)
				}
			}
		}
		// Surface live-view-start failures (Nikon LiveViewProhibitCondition,
		// Canon EVF stuck, etc.) to the agent so the user gets an NSAlert
		// explaining why their QuickTime preview is black, instead of just
		// staring at a blank window.
		camera.onLiveViewStartFailed = { [weak self] reason in
			guard let self else { return }
			let cameraName = self.deviceSources[cameraId]?.device.localizedName ?? cameraId
			self.publishLiveViewFailure(cameraName: cameraName, reason: reason)
		}
		camera.onPropertiesDiscovered = { [weak self, weak camera] discovered in
			guard let self = self else { return }
			DispatchQueue.main.async {
				if self.cameraProperties[cameraId] == nil {
					self.cameraProperties[cameraId] = discovered
				} else {
					for (k, v) in discovered { self.cameraProperties[cameraId]![k] = v }
				}
				// If the USB device descriptor didn't provide a serial number
				// (common on Canon EOS bodies), use the one extracted from
				// the PTP GetDeviceInfo response instead.
				if let ptpSerial = (camera as? UsbPtpCameraBase)?.deviceSerial,
				   !ptpSerial.isEmpty,
				   let existing = self.cameraIdentity[cameraId],
				   existing.serial.isEmpty {
					self.cameraIdentity[cameraId] = (vid: existing.vid, pid: existing.pid, serial: ptpSerial)
					PtpWebcamCameraExtensionProviderSource.log("PTP serial \(ptpSerial) replaces empty USB-descriptor serial for \(cameraId)")
					// The agent computes the notify suffix from the PUBLISHED
					// serial; we just changed what we publish, so we must also
					// listen on the new suffix or SET_PROP commands sent under
					// the new key never reach us.
					self.registerPerCameraNotifyChannels(cameraId: cameraId,
					                                    vid: existing.vid,
					                                    pid: existing.pid,
					                                    serial: ptpSerial)
				}
				self.publishPropertyState(cameraId: cameraId)
			}
		}

		// Store camera on main, then open session. Check pending live view request.
		// If the camera was unplugged during our ~3 s of retries above,
		// `cameraDisconnected` has already run and cleared `cameraIdentity` —
		// in that case bail and close the transport instead of leaking a
		// live IOUSBLib handle for a service that no longer exists.
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
			guard self.cameraIdentity[cameraId] != nil else {
				PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: camera \(cameraId) disconnected during claim — discarding")
				camera.close()
				return
			}
			self.usbCameras[cameraId] = camera
			PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: camera stored, opening session for \(cameraId)")
			camera.openSessionAndDiscover()
			if self.pendingLiveViewStart.remove(cameraId) != nil {
				PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: fulfilling pending live view start for \(cameraId)")
				camera.startLiveView()
			}
		}
		PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: transport ready vid=0x\(String(t.vendorId, radix:16)) pid=0x\(String(t.productId, radix:16)) for \(cameraId)")
	}

	func connect(to client: CMIOExtensionClient) throws {
	}

	func disconnect(from client: CMIOExtensionClient) {
	}

	var availableProperties: Set<CMIOExtensionProperty> {
		return [.providerManufacturer]
	}

	func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
		let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
		if properties.contains(.providerManufacturer) {
			providerProperties.manufacturer = "PTP Webcam"
		}
		return providerProperties
	}

	func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
	}

	// MARK: - PTP dump (extension → app)
	//
	// Lists every attached PTP/MTP Still Imaging USB interface and lets the app
	// request a full GetDeviceInfo + GetDevicePropDesc dump for any one of them.
	// Works for unsupported cameras too — the dump only relies on standard PTP
	// opcodes (0x1002 OpenSession, 0x1001 GetDeviceInfo, 0x1014 GetDevicePropDesc,
	// 0x1003 CloseSession), so it produces useful output for adding new vendors.

	private struct PtpDumpDevice {
		let locationID: UInt32
		let vid: UInt16
		let pid: UInt16
		let productName: String
		let serial: String
	}

	private func enumeratePtpDumpDevices() -> [PtpDumpDevice] {
		var out: [PtpDumpDevice] = []
		for svc in UsbPtpTransport.findPtpServices() {
			defer { IOObjectRelease(svc) }
			var vid: UInt16 = 0
			var pid: UInt16 = 0
			var name: NSString?
			var serial: NSString?
			UsbPtpBridge.readVendorID(&vid, productID: &pid,
			                          productName: &name, serialNumber: &serial,
			                          fromService: svc)
			let loc = Self.readLocationID(svc) ?? 0
			out.append(.init(locationID: loc, vid: vid, pid: pid,
			                 productName: (name as String?) ?? "USB Device",
			                 serial: (serial as String?) ?? ""))
		}
		return out
	}

	/// Reads the kUSBDevicePropertyLocationID from an interface service or one
	/// of its USB device ancestors. Each USB device has a unique location ID
	/// derived from the physical port chain, so it's stable across replug.
	private static func readLocationID(_ service: io_service_t) -> UInt32? {
		// Walk up the IORegistry until we find an entry with "locationID".
		var current = service
		IOObjectRetain(current)
		for _ in 0..<8 {
			var props: Unmanaged<CFMutableDictionary>?
			if IORegistryEntryCreateCFProperties(current, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
			   let dict = props?.takeRetainedValue() as? [String: Any],
			   let loc = dict["locationID"] as? UInt32 {
				IOObjectRelease(current)
				return loc
			}
			var parent: io_registry_entry_t = 0
			if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS {
				IOObjectRelease(current)
				return nil
			}
			IOObjectRelease(current)
			current = parent
		}
		IOObjectRelease(current)
		return nil
	}

	fileprivate func publishDumpDevicesList() {
		let devices = enumeratePtpDumpDevices()
		let payload: [[String: Any]] = devices.map { d in
			[
				"loc":    d.locationID,
				"vid":    d.vid,
				"pid":    d.pid,
				"name":   d.productName,
				"serial": d.serial,
			]
		}
		guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
		publishQueue.async { [weak self] in
			guard let self else { return }
			self.publishBytesViaSlotChain(json,
			                              tokens: self.dumpDevicesSlotTokens,
			                              notificationName: kDarwinPtpDumpDevicesState)
		}
		Self.log("publishDumpDevicesList: \(devices.count) device(s), \(json.count)B")
	}

	/// Publish a live-view start failure to the agent over the dedicated
	/// slot chain. Format: "<Camera Name>\n<reason>". The agent reads it,
	/// shows an NSAlert, and the user gets a clear explanation instead of
	/// a silent black QuickTime preview.
	/// Publish a USB-busy / camera-held-by-other-app signal to the agent
	/// over the dedicated slot chain. Payload is the cameraId so the
	/// agent can map it back to the matching ExtCamera entry, find which
	/// running apps are likely holding ptpcamerad, and surface them as
	/// actionable menu items.
	fileprivate func publishUsbBlocked(cameraId: String) {
		guard let data = cameraId.data(using: .utf8) else { return }
		publishQueue.async { [weak self] in
			guard let self else { return }
			self.publishBytesViaSlotChain(data,
			                              tokens: self.usbBlockedSlotTokens,
			                              notificationName: kDarwinUsbBlocked)
		}
		Self.log("publishUsbBlocked: \(cameraId)")
	}

	fileprivate func publishLiveViewFailure(cameraName: String, reason: String) {
		let combined = "\(cameraName)\n\(reason)"
		guard let data = combined.data(using: .utf8) else { return }
		publishQueue.async { [weak self] in
			guard let self else { return }
			self.publishBytesViaSlotChain(data,
			                              tokens: self.lvFailSlotTokens,
			                              notificationName: kDarwinLiveViewFailed)
		}
		Self.log("publishLiveViewFailure: \(cameraName) — \(reason)")
	}

	fileprivate func handleDumpCommand(locationID: UInt32) {
		// Run on the dump queue — performing PTP I/O on .main would block the
		// IOKit notification handler.
		dumpQueue.async { [weak self] in
			guard let self else { return }
			let text = self.performDump(locationID: locationID)
			guard let data = text.data(using: .utf8) else { return }
			self.publishBytesViaSlotChain(data,
			                              tokens: self.dumpTextSlotTokens,
			                              notificationName: kDarwinPtpDumpText)
			Self.log("publishDumpText: \(data.count)B for locationID=0x\(String(locationID, radix: 16))")
		}
	}

	/// Sentinel prefix the app watches for. When the camera is claimed AND
	/// currently streaming live view we can't dump without disrupting the
	/// stream, so the extension returns just this marker plus a short label.
	/// The app then presents a "Stop live view and dump?" / "Cancel" dialog.
	static let kPtpDumpBusyPrefix = "[BUSY]"

	private func performDump(locationID: UInt32) -> String {
		// Find the matching IOKit service by locationID.
		var matchedSvc: io_service_t = IO_OBJECT_NULL
		for svc in UsbPtpTransport.findPtpServices() {
			if Self.readLocationID(svc) == locationID && matchedSvc == IO_OBJECT_NULL {
				matchedSvc = svc
			} else {
				IOObjectRelease(svc)
			}
		}
		guard matchedSvc != IO_OBJECT_NULL else {
			return "PTP dump failed: no USB device with locationID 0x\(String(locationID, radix: 16)) currently attached.\n"
		}
		defer { IOObjectRelease(matchedSvc) }

		var vid: UInt16 = 0, pid: UInt16 = 0
		var prodName: NSString?
		UsbPtpBridge.readVendorID(&vid, productID: &pid,
		                          productName: &prodName, serialNumber: nil,
		                          fromService: matchedSvc)
		let label = String(format: "%04X:%04X %@", vid, pid, (prodName as String?) ?? "")
		                    .trimmingCharacters(in: .whitespaces)

		// Three-way decision based on whether this physical device is already
		// owned by one of our UsbCamera instances:
		//
		//   - Owned + live view active → BUSY sentinel. Dumping would either
		//     contend on the USB endpoints (fresh transport) or interleave
		//     with the camera's poll loop in a way that risks corrupting
		//     bulk-IN state. Let the app surface a dialog and try again.
		//   - Owned + idle             → synthesise dump from cached state.
		//     No I/O at all, completely safe regardless of session state.
		//   - Not owned                → open a fresh transport and run the
		//     full live PTP dump. Works for unsupported VID/PIDs too.
		let claimed = usbCameras.values
			.compactMap { $0 as? UsbPtpCameraBase }
			.first { $0.transport.vendorId == vid && $0.transport.productId == pid }
		if let claimed {
			if claimed.liveViewRunning {
				return "\(Self.kPtpDumpBusyPrefix) \(label)\n"
			}
			Self.log("PTP dump from cache: \(label)")
			return claimed.generateInMemoryDump()
		}

		Self.log("PTP dump (live transport): \(label)")
		do {
			let transport = try UsbPtpTransport(service: matchedSvc)
			defer { transport.close() }
			let dumper = PtpDumper(transport: transport)
			return dumper.run()
		} catch {
			return "PTP dump failed: \(error)\n"
		}
	}
}

// MARK: - PtpCameraAgentDelegateProtocol

extension PtpWebcamCameraExtensionProviderSource: PtpCameraAgentDelegateProtocol {

	func cameraConnected(_ cameraId: String, info: NSDictionary) {
		let vid    = (info["vid"]    as? NSNumber)?.uint16Value ?? 0
		let pid    = (info["pid"]    as? NSNumber)?.uint16Value ?? 0
		let serial = (info["serial"] as? String) ?? ""
		cameraIdentity[cameraId] = (vid: vid, pid: pid, serial: serial)

		// Use the shared known-cameras lookup for the CMIO device name so
		// everything (QuickTime's device list, the agent's menu, and the
		// ptpwebcam://preview URL) agrees. Previously the CMIO device kept
		// the raw USB descriptor name ("ILCE-1") while the agent rewrote
		// its menu to "Sony A1" — the preview URL then carried "Sony A1"
		// but no AVCaptureDevice by that name existed, so the live view
		// stream never started.
		let usbName = info["name"] as? String ?? "PTP Camera"
		let name    = PtpKnownCameras.displayName(vid: vid, pid: pid, fallback: usbName)
		PtpWebcamCameraExtensionProviderSource.log("cameraConnected: \(name) (\(cameraId))")

		guard deviceSources[cameraId] == nil else { return }

		let isDemo = (info["isDemo"] as? String) == "1"
		let deviceSource = PtpWebcamCameraExtensionDeviceSource(localizedName: name, cameraId: cameraId, isDemo: isDemo)
		if let speed = info["stripeSpeed"] as? String { deviceSource.applyStripeSpeed(speed) }

		deviceSource.onStreamingStarted = { [weak self] in
			guard let self = self else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming started for \(cameraId)")
			// Only start live view if camera has been claimed (PTP session is open).
			if let camera = self.usbCameras[cameraId] {
				camera.startLiveView()
			} else {
				PtpWebcamCameraExtensionProviderSource.log("streaming started but camera not claimed — no live view for \(cameraId)")
			}
		}
		deviceSource.onStreamingStopped = { [weak self] in
			guard let self = self else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming stopped for \(cameraId)")
			self.pendingLiveViewStart.remove(cameraId)
			// Stop live view but keep PTP session open — claimed camera stays claimed.
			self.usbCameras[cameraId]?.stopLiveView()
		}

		deviceSources[cameraId] = deviceSource

		do {
			try provider.addDevice(deviceSource.device)
			PtpWebcamCameraExtensionProviderSource.log("Added device: \(name)")
		} catch {
			PtpWebcamCameraExtensionProviderSource.log("Failed to add device: \(error.localizedDescription)")
		}

		// Register per-camera claim + property-command channels keyed by
		// vid.pid.crc(serial). For Canon EOS bodies the USB descriptor reports
		// an empty serial; the real PTP serial only becomes available after
		// GetDeviceInfo runs. We register a SECOND set of channels under the
		// PTP-derived suffix in the onPropertiesDiscovered callback so that
		// the agent's commands (which use the published PTP serial) reach us.
		registerPerCameraNotifyChannels(cameraId: cameraId, vid: vid, pid: pid, serial: serial)

		// Announce to agent so it can show the camera in the menu (unclaimed state).
		publishCameraConnected(cameraId: cameraId)
	}

	func cameraDisconnected(_ cameraId: String) {
		PtpWebcamCameraExtensionProviderSource.log("cameraDisconnected: \(cameraId)")
		pendingLiveViewStart.remove(cameraId)
		if let camera = usbCameras.removeValue(forKey: cameraId) {
			camera.close()
		}
		cameraProperties.removeValue(forKey: cameraId)
		cameraIdentity.removeValue(forKey: cameraId)
		for tokens in claimTokens.removeValue(forKey: cameraId) ?? [] {
			notify_cancel(tokens.slot)
			notify_cancel(tokens.notify)
		}
		for tokens in propCmdTokens.removeValue(forKey: cameraId) ?? [] {
			notify_cancel(tokens.slot)
			notify_cancel(tokens.notify)
		}
		registeredSuffixes.removeValue(forKey: cameraId)

		// Tell the agent to remove this camera from its menu before we drop the device.
		publishCameraRemoved(cameraId: cameraId)

		guard let deviceSource = deviceSources.removeValue(forKey: cameraId) else { return }
		do {
			try provider.removeDevice(deviceSource.device)
			PtpWebcamCameraExtensionProviderSource.log("Removed device for \(cameraId)")
		} catch {
			PtpWebcamCameraExtensionProviderSource.log("Failed to remove device: \(error.localizedDescription)")
		}
	}

	func receivedLiveViewJpegData(_ jpegData: Data, info: NSDictionary, forCamera cameraId: String) {
		// Not used — live view is handled directly by UsbNikonCamera in the extension.
	}

	func propertyChanged(_ property: NSDictionary, forCamera cameraId: String) {
		// Not used — the agent handles property display via menu rebuild.
	}
}
