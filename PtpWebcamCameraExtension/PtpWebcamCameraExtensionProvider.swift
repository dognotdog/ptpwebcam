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
	private var _bufferPool: CVPixelBufferPool!
	private var _bufferAuxAttributes: NSDictionary!

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

		let pixelBufferAttributes: NSDictionary = [
			kCVPixelBufferWidthKey: dims.width,
			kCVPixelBufferHeightKey: dims.height,
			kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
		]
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

		let videoStreamFormat = CMIOExtensionStreamFormat(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
		_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

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
		guard _bufferPool != nil else { return }
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

	// Allocate a CVPixelBuffer from the pool for live view frames.
	func createPixelBuffer() -> CVPixelBuffer? {
		guard _bufferPool != nil else { return nil }
		var pb: CVPixelBuffer?
		let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
			kCFAllocatorDefault, _bufferPool, _bufferAuxAttributes, &pb)
		guard err == kCVReturnSuccess else { return nil }
		return pb
	}

	// Send a live-view frame to CMIO, deriving format description from actual pixel buffer dimensions.
	func sendLiveViewFrame(_ pixelBuffer: CVPixelBuffer) {
		guard _streamingCounter > 0 else { return }

		var formatDesc: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
		guard let fd = formatDesc else { return }

		var timingInfo = CMSampleTimingInfo()
		timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
		var sbuf: CMSampleBuffer?
		let err = CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
			makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
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
		err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool, _bufferAuxAttributes, &pixelBuffer)
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

		var sbuf: CMSampleBuffer!
		var timingInfo = CMSampleTimingInfo()
		timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
		err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: _videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
		if err == 0 {
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

	private let logger = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "Provider")
	private var deviceSources: [String: PtpWebcamCameraExtensionDeviceSource] = [:]

	private static let extLogger = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "ExtLog")

	static func log(_ msg: String) {
		extLogger.fault("\(msg, privacy: .public)")
	}

	// USB cameras keyed by cameraId — created at camera connect time.
	private var usbCameras: [String: UsbNikonCamera] = [:]

	// Camera IDs that received a streaming-start request before the USB camera was ready.
	private var pendingLiveViewStart: Set<String> = []

	// Discovered camera properties keyed by cameraId, then by propertyId.
	private var cameraProperties: [String: [UInt16: NikonDiscoveredProperty]] = [:]

	// Darwin notify tokens for property state slots (extension → agent).
	private var propSlotTokens: [Int32] = []
	// Darwin notify token for the property command slot (agent → extension).
	private var propCmdToken: Int32 = 0

	// IOKit USB device detection (replaces ICDeviceBrowser / Darwin notify camera state).
	private var ioNotificationPort: IONotificationPortRef?
	private var ioAddedIterator:   io_iterator_t = IO_OBJECT_NULL
	private var ioRemovedIterator: io_iterator_t = IO_OBJECT_NULL

	init(clientQueue: DispatchQueue?) {

		super.init()

		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

		// Register property state slots (extension → agent).
		propSlotTokens = (0..<kDarwinPropertySlotCount).map { i in
			var token: Int32 = 0
			darwin_notify_register_check(kDarwinPropertySlotPrefix + "\(i)", &token)
			return token
		}

		// Register command slot and subscribe to property command notification (agent → extension).
		darwin_notify_register_check(kDarwinPropertyCmdSlot, &propCmdToken)
		var propCmdNotifyToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinCameraPropertyCmd, &propCmdNotifyToken, .main) { [weak self] _ in
			self?.handlePropertyCommand()
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
			if prop.writable, let e = prop.enumValues { entry["e"] = Array(e.prefix(32)) }
			if let rmin = prop.rangeMin, let rmax = prop.rangeMax, let rstep = prop.rangeStep {
				entry["r"] = ["min": rmin, "max": rmax, "step": rstep]
			}
			propsList.append(entry)
		}
		let dict: [String: Any] = ["id": cameraId, "props": propsList]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
		writeJsonToPropertySlots(jsonData)
		PtpWebcamCameraExtensionProviderSource.log("publishPropertyState: \(jsonData.count)B for \(cameraId)")
	}

	private func publishCameraRemoved(cameraId: String) {
		let dict: [String: Any] = ["id": cameraId, "disconnected": true, "props": []]
		guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
		writeJsonToPropertySlots(jsonData)
		PtpWebcamCameraExtensionProviderSource.log("publishCameraRemoved: \(cameraId)")
	}

	private func writeJsonToPropertySlots(_ jsonData: Data) {
		// Multi-page protocol: slot 0 = header, slots 1..(N-2) = data, slot N-1 = checksum.
		let pageDataSlots = kDarwinPropertySlotCount - 2
		let pageSize = pageDataSlots * 8
		let totalLength = jsonData.count
		let pageCount = max(1, (totalLength + pageSize - 1) / pageSize)
		let checksumSlot = kDarwinPropertySlotCount - 1

		for pageIndex in 0..<pageCount {
			let pageOffset = pageIndex * pageSize
			let pageEnd = min(pageOffset + pageSize, totalLength)
			let pageLength = pageEnd - pageOffset

			let header = (UInt64(totalLength) << 32) | (UInt64(pageIndex) << 16) | UInt64(pageCount)
			darwin_notify_set_state(propSlotTokens[0], header)

			for i in 0..<((pageLength + 7) / 8) {
				let chunkOffset = pageOffset + i * 8
				let chunkSize = min(8, totalLength - chunkOffset)
				var value: UInt64 = 0
				_ = jsonData.withUnsafeBytes { ptr in
					memcpy(&value, ptr.baseAddress! + chunkOffset, chunkSize)
				}
				darwin_notify_set_state(propSlotTokens[i + 1], value)
			}

			var checksum: UInt32 = 0
			for byte in jsonData[pageOffset..<pageEnd] { checksum = checksum &+ UInt32(byte) }
			darwin_notify_set_state(propSlotTokens[checksumSlot], UInt64(checksum))

			darwin_notify_post(kDarwinCameraPropertyState)
		}
	}

	// MARK: - Property Command (agent → extension)

	private func handlePropertyCommand() {
		var packed: UInt64 = 0
		darwin_notify_get_state(propCmdToken, &packed)
		let cmd    = UInt8((packed >> 56) & 0xFF)
		let propId = UInt16((packed >> 32) & 0xFFFF)
		let value  = UInt32(packed & 0xFFFFFFFF)

		guard cmd == 3 else {
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: unknown cmd=\(cmd)")
			return
		}

		// Find active camera with this property.
		guard let (cameraId, camera) = usbCameras.first else {
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: no active camera")
			return
		}
		guard let dataType = cameraProperties[cameraId]?[propId]?.dataType else {
			PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: unknown propId=0x\(String(propId, radix:16))")
			return
		}
		PtpWebcamCameraExtensionProviderSource.log("handlePropertyCommand: SET_PROP 0x\(String(propId, radix:16))=\(value) on \(cameraId)")
		camera.setProperty(propId: propId, value: value, dataType: dataType)
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

			var vid: UInt16 = 0; var pid: UInt16 = 0; var nsName: NSString?
			UsbPtpBridge.readVendorID(&vid, productID: &pid, productName: &nsName, fromService: svc)
			let name = (nsName as String?) ?? "PTP Camera"

			PtpWebcamCameraExtensionProviderSource.log(
				"IOKit: attached vid=0x\(String(vid, radix:16)) pid=0x\(String(pid, radix:16)) \"\(name)\" id=\(cameraId)")
			cameraConnected(cameraId, info: ["name": name, "cameraId": cameraId] as NSDictionary)
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
	private func openUsbCamera(cameraId: String, deviceSource: PtpWebcamCameraExtensionDeviceSource) {
		PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: requesting USB access (killing ptpcamerad)")
		darwin_notify_post(kDarwinNeedUsbAccess)

		var transport: UsbPtpTransport?
		var lastError: Error?
		for attempt in 1...10 {
			Thread.sleep(forTimeInterval: 0.3)
			let services = UsbPtpTransport.findPtpServices()
			guard !services.isEmpty else {
				if attempt == 1 { PtpWebcamCameraExtensionProviderSource.log("openUsbCamera: no PTP service yet") }
				continue
			}
			let svc = services[0]
			services.dropFirst().forEach { IOObjectRelease($0) }
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
			return
		}

		let camera = UsbNikonCamera(transport: t)
		camera.onJpegFrame = { [weak deviceSource] jpegData in
			guard let ds = deviceSource else { return }
			if let pb = jpegToPixelBuffer(jpegData) {
				ds.sendLiveViewFrame(pb)
			}
		}
		camera.onPropertiesDiscovered = { [weak self] discovered in
			guard let self = self else { return }
			DispatchQueue.main.async {
				if self.cameraProperties[cameraId] == nil {
					self.cameraProperties[cameraId] = discovered
				} else {
					for (k, v) in discovered { self.cameraProperties[cameraId]![k] = v }
				}
				self.publishPropertyState(cameraId: cameraId)
			}
		}

		// Store camera on main, then open session. Check pending live view request.
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }
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
}

// MARK: - PtpCameraAgentDelegateProtocol

extension PtpWebcamCameraExtensionProviderSource: PtpCameraAgentDelegateProtocol {

	func cameraConnected(_ cameraId: String, info: NSDictionary) {
		let name = info["name"] as? String ?? "PTP Camera"
		PtpWebcamCameraExtensionProviderSource.log("cameraConnected: \(name) (\(cameraId))")

		guard deviceSources[cameraId] == nil else { return }

		let isDemo = (info["isDemo"] as? String) == "1"
		let deviceSource = PtpWebcamCameraExtensionDeviceSource(localizedName: name, cameraId: cameraId, isDemo: isDemo)
		if let speed = info["stripeSpeed"] as? String { deviceSource.applyStripeSpeed(speed) }

		deviceSource.onStreamingStarted = { [weak self] in
			guard let self = self else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming started for \(cameraId)")
			if let camera = self.usbCameras[cameraId] {
				camera.startLiveView()
			} else {
				PtpWebcamCameraExtensionProviderSource.log("streaming started but camera not ready yet — queuing for \(cameraId)")
				self.pendingLiveViewStart.insert(cameraId)
			}
		}
		deviceSource.onStreamingStopped = { [weak self] in
			guard let self = self else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming stopped for \(cameraId)")
			self.pendingLiveViewStart.remove(cameraId)
			self.usbCameras[cameraId]?.stopLiveView()
		}

		deviceSources[cameraId] = deviceSource

		// Start USB session immediately at connect time (not at streaming time).
		if !isDemo {
			DispatchQueue.global(qos: .userInteractive).async { [weak self] in
				self?.openUsbCamera(cameraId: cameraId, deviceSource: deviceSource)
			}
		}

		do {
			try provider.addDevice(deviceSource.device)
			PtpWebcamCameraExtensionProviderSource.log("Added device: \(name)")
		} catch {
			PtpWebcamCameraExtensionProviderSource.log("Failed to add device: \(error.localizedDescription)")
		}
	}

	func cameraDisconnected(_ cameraId: String) {
		PtpWebcamCameraExtensionProviderSource.log("cameraDisconnected: \(cameraId)")
		pendingLiveViewStart.remove(cameraId)
		if let camera = usbCameras.removeValue(forKey: cameraId) {
			camera.close()
		}
		cameraProperties.removeValue(forKey: cameraId)

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
