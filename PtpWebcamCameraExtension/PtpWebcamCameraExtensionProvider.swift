//
//  PtpWebcamCameraExtensionProvider.swift
//  PtpWebcamCameraExtension
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 Doemoetoer Gulyas. All rights reserved.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import IOSurface
import CoreVideo
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

	// Called by the provider when a live view frame arrives from the agent via IOSurface.
	func sendLiveViewPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
		guard _streamingCounter > 0 else { return }

		var formatDescription: CMFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
		guard let fd = formatDescription else { return }

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

	private var darwinSlotTokens: [Int32] = []
	private var lvFrameSlotTokens: [Int32] = []
	private var lvCmdSlotTokens: [Int32] = []

	init(clientQueue: DispatchQueue?) {

		super.init()

		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

		PtpWebcamCameraExtensionProviderSource.log("Extension init v5 (Darwin state slots + IOSurface live view)")

		darwinSlotTokens = (0..<kDarwinStateSlotCount).map { i in
			var token: Int32 = 0
			darwin_notify_register_check(kDarwinStateSlotPrefix + "\(i)", &token)
			return token
		}

		lvFrameSlotTokens = (0..<kDarwinLiveViewFrameSlotCount).map { i in
			var token: Int32 = 0
			darwin_notify_register_check(kDarwinLiveViewFrameSlotPrefix + "\(i)", &token)
			return token
		}

		lvCmdSlotTokens = (0..<kDarwinLiveViewCmdSlotCount).map { i in
			var token: Int32 = 0
			darwin_notify_register_check(kDarwinLiveViewCmdSlotPrefix + "\(i)", &token)
			return token
		}

		var stateToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinCameraStateChanged, &stateToken, .main) { [weak self] _ in
			self?.readCameraState()
		}

		var lvFrameToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinLiveViewFrame, &lvFrameToken, .main) { [weak self] _ in
			self?.handleLiveViewFrame()
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
			PtpWebcamCameraExtensionProviderSource.log("Requesting camera state from agent")
			darwin_notify_post(kDarwinCameraStateRequest)
		}
	}

	private func readCameraState() {
		var lengthState: UInt64 = 0
		darwin_notify_get_state(darwinSlotTokens[0], &lengthState)
		let length = Int(lengthState >> 32)

		guard length > 0 && length <= (kDarwinStateSlotCount - 1) * 8 else {
			PtpWebcamCameraExtensionProviderSource.log("readCameraState: invalid length \(length)")
			return
		}

		var jsonData = Data(count: length)
		let slotCount = (length + 7) / 8
		for i in 0..<slotCount {
			var value: UInt64 = 0
			darwin_notify_get_state(darwinSlotTokens[i + 1], &value)
			let offset = i * 8
			let chunkSize = min(8, length - offset)
			_ = jsonData.withUnsafeMutableBytes { ptr in
				memcpy(ptr.baseAddress! + offset, &value, chunkSize)
			}
		}

		guard let cameras = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
			PtpWebcamCameraExtensionProviderSource.log("readCameraState: failed to parse JSON (\(length) bytes)")
			return
		}

		PtpWebcamCameraExtensionProviderSource.log("readCameraState: \(cameras.count) camera(s)")
		applyCameraState(cameras)
	}

	private func applyCameraState(_ cameras: [[String: String]]) {
		let newCameraIds = Set(cameras.compactMap { $0["cameraId"] })
		let existingIds = Set(deviceSources.keys)

		for camera in cameras {
			guard let cameraId = camera["cameraId"] else { continue }
			if existingIds.contains(cameraId) {
				if let speed = camera["stripeSpeed"] {
					deviceSources[cameraId]?.applyStripeSpeed(speed)
				}
			} else {
				let name = camera["name"] ?? "PTP Camera"
				var info: [String: String] = ["name": name, "cameraId": cameraId]
				if let isDemo = camera["isDemo"] { info["isDemo"] = isDemo }
				if let speed = camera["stripeSpeed"] { info["stripeSpeed"] = speed }
				cameraConnected(cameraId, info: info as NSDictionary)
			}
		}

		for cameraId in existingIds.subtracting(newCameraIds) {
			cameraDisconnected(cameraId)
		}
	}

	private func handleLiveViewFrame() {
		var slot0: UInt64 = 0
		darwin_notify_get_state(lvFrameSlotTokens[0], &slot0)
		let surfaceId = IOSurfaceID(slot0 >> 32)
		let cameraIdLength = Int(slot0 & 0xFFFFFFFF)

		guard surfaceId > 0, cameraIdLength > 0,
			  cameraIdLength <= (kDarwinLiveViewFrameSlotCount - 1) * 8 else { return }

		var cameraIdData = Data(count: cameraIdLength)
		let slotCount = (cameraIdLength + 7) / 8
		for i in 0..<slotCount {
			var value: UInt64 = 0
			darwin_notify_get_state(lvFrameSlotTokens[i + 1], &value)
			let offset = i * 8
			let chunkSize = min(8, cameraIdLength - offset)
			_ = cameraIdData.withUnsafeMutableBytes { ptr in
				memcpy(ptr.baseAddress! + offset, &value, chunkSize)
			}
		}
		guard let cameraId = String(data: cameraIdData, encoding: .utf8),
			  let deviceSource = deviceSources[cameraId] else { return }

		guard let surface = IOSurfaceLookup(surfaceId) else {
			PtpWebcamCameraExtensionProviderSource.log("handleLiveViewFrame: IOSurface \(surfaceId) not found")
			return
		}

		var unmanagedPb: Unmanaged<CVPixelBuffer>?
		CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedPb)
		guard let pb = unmanagedPb?.takeRetainedValue() else { return }

		deviceSource.sendLiveViewPixelBuffer(pb)
	}

	private func postLiveViewCommand(_ notifyName: String, cameraId: String) {
		let data = cameraId.data(using: .utf8) ?? Data()
		darwin_notify_set_state(lvCmdSlotTokens[0], UInt64(data.count))
		let slotCount = min((data.count + 7) / 8, kDarwinLiveViewCmdSlotCount - 1)
		for i in 0..<slotCount {
			var value: UInt64 = 0
			let offset = i * 8
			let chunkSize = min(8, data.count - offset)
			_ = data.withUnsafeBytes { ptr in
				memcpy(&value, ptr.baseAddress! + offset, chunkSize)
			}
			darwin_notify_set_state(lvCmdSlotTokens[i + 1], value)
		}
		darwin_notify_post(notifyName)
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

		deviceSource.onStreamingStarted = { [weak self, weak deviceSource] in
			guard let self = self, let ds = deviceSource else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming started for \(ds.cameraId)")
			self.postLiveViewCommand(kDarwinLiveViewStart, cameraId: ds.cameraId)
		}
		deviceSource.onStreamingStopped = { [weak self, weak deviceSource] in
			guard let self = self, let ds = deviceSource else { return }
			PtpWebcamCameraExtensionProviderSource.log("streaming stopped for \(ds.cameraId)")
			self.postLiveViewCommand(kDarwinLiveViewStop, cameraId: ds.cameraId)
		}

		deviceSources[cameraId] = deviceSource

		do {
			try provider.addDevice(deviceSource.device)
			PtpWebcamCameraExtensionProviderSource.log("Added device: \(name)")
		} catch {
			PtpWebcamCameraExtensionProviderSource.log("Failed to add device: \(error.localizedDescription)")
		}
	}

	func cameraDisconnected(_ cameraId: String) {
		PtpWebcamCameraExtensionProviderSource.log("cameraDisconnected: \(cameraId)")

		guard let deviceSource = deviceSources.removeValue(forKey: cameraId) else { return }

		do {
			try provider.removeDevice(deviceSource.device)
			PtpWebcamCameraExtensionProviderSource.log("Removed device for \(cameraId)")
		} catch {
			PtpWebcamCameraExtensionProviderSource.log("Failed to remove device: \(error.localizedDescription)")
		}
	}

	func receivedLiveViewJpegData(_ jpegData: Data, info: NSDictionary, forCamera cameraId: String) {
		// Live view frames now arrive via Darwin notify + IOSurface (handleLiveViewFrame).
		// This XPC path is unused but kept for protocol conformance.
	}

	func propertyChanged(_ property: NSDictionary, forCamera cameraId: String) {
		// not used — the agent handles property display via menu rebuild
	}
}
