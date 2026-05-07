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
import os.log

let kWhiteStripeHeight: Int = 10
let kFrameRate: Int = 60

// MARK: -

class PtpWebcamCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
	
	private(set) var device: CMIOExtensionDevice!
	
	private var _streamSource: PtpWebcamCameraExtensionStreamSource!
	
	private var _streamingCounter: UInt32 = 0
	
	private var _timer: DispatchSourceTimer?
	
	private let _timerQueue = DispatchQueue(label: "timerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
	private var _videoDescription: CMFormatDescription!
	
	private var _bufferPool: CVPixelBufferPool!
	
	private var _bufferAuxAttributes: NSDictionary!
	
	private var _whiteStripeStartRow: UInt32 = 0
	
	private var _whiteStripeIsAscending: Bool = false
	
	init(localizedName: String) {
		
		super.init()
		let deviceID = UUID() // replace this with your device UUID
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
		
		let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
		_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
		
		let videoID = UUID() // replace this with your video UUID
		_streamSource = PtpWebcamCameraExtensionStreamSource(localizedName: "SampleCapture.Video", streamID: videoID, streamFormat: videoStreamFormat, device: device)
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
			deviceProperties.model = "PtpWebcamMock"
		}
		
		return deviceProperties
	}
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
		
		// Handle settable properties here.
	}
	
	func startStreaming() {
		
		guard let _ = _bufferPool else {
			return
		}
		
		_streamingCounter += 1
		
		_timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
		_timer!.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .seconds(0))
		
		_timer!.setEventHandler {
			
			var err: OSStatus = 0
			let now = CMClockGetTime(CMClockGetHostTimeClock())
			
			var pixelBuffer: CVPixelBuffer?
			err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
			if err != 0 {
				os_log(.error, "out of pixel buffers \(err)")
			}
			
			if let pixelBuffer = pixelBuffer {
				
				CVPixelBufferLockBaseAddress(pixelBuffer, [])
				
				var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
				let width = CVPixelBufferGetWidth(pixelBuffer)
				let height = CVPixelBufferGetHeight(pixelBuffer)
				let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
				memset(bufferPtr, 0, rowBytes * height)
				
				let whiteStripeStartRow = self._whiteStripeStartRow
				if self._whiteStripeIsAscending {
					self._whiteStripeStartRow = whiteStripeStartRow - 1
					self._whiteStripeIsAscending = self._whiteStripeStartRow > 0
				}
				else {
					self._whiteStripeStartRow = whiteStripeStartRow + 1
					self._whiteStripeIsAscending = self._whiteStripeStartRow >= (height - kWhiteStripeHeight)
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
				err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
				if err == 0 {
					self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				}
				os_log(.info, "video time \(timingInfo.presentationTimeStamp.seconds) now \(now.seconds) err \(err)")
			}
		}
		
		_timer!.setCancelHandler {
		}
		
		_timer!.resume()
	}
	
	func stopStreaming() {
		
		if _streamingCounter > 1 {
			_streamingCounter -= 1
		}
		else {
			_streamingCounter = 0
			if let timer = _timer {
				timer.cancel()
				_timer = nil
			}
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
		
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
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

	init(clientQueue: DispatchQueue?) {

		super.init()

		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

		PtpWebcamCameraExtensionProviderSource.log("Extension init v4 (Darwin state slots)")

		darwinSlotTokens = (0..<kDarwinStateSlotCount).map { i in
			var token: Int32 = 0
			darwin_notify_register_check(kDarwinStateSlotPrefix + "\(i)", &token)
			return token
		}

		var stateToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinCameraStateChanged, &stateToken, .main) { [weak self] _ in
			self?.readCameraState()
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
			jsonData.withUnsafeMutableBytes { ptr in
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
			guard let cameraId = camera["cameraId"], !existingIds.contains(cameraId) else { continue }
			let name = camera["name"] ?? "PTP Camera"
			cameraConnected(cameraId, info: ["name": name, "cameraId": cameraId] as NSDictionary)
		}

		for cameraId in existingIds.subtracting(newCameraIds) {
			cameraDisconnected(cameraId)
		}
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

		let deviceSource = PtpWebcamCameraExtensionDeviceSource(localizedName: name)
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
		// TODO: Phase 4 — convert JPEG to CVPixelBuffer and send to stream
	}

	func propertyChanged(_ property: NSDictionary, forCamera cameraId: String) {
		// TODO: Phase 6 — update CMIOExtension properties
	}
}
