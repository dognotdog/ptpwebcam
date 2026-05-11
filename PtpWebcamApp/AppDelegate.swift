//
//  AppDelegate.swift
//  PtpWebcamApp
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 org.ptpwebcam. All rights reserved.
//

import Cocoa
import ServiceManagement
import SystemExtensions
import OSLog
import AVFoundation

@main
class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {

	private let log = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp", category: "AppDelegate")
	private let extensionIdentifier = "org.ptpwebcam.CameraExtension"
	private let agentPlistName = "org.ptpwebcam.PtpCameraAgent.plist"
	private let agentLabel     = "org.ptpwebcam.PtpCameraAgent"

	// MARK: - OSSystemExtensionRequestDelegate

	func request(_ request: OSSystemExtensionRequest,
				 actionForReplacingExtension existing: OSSystemExtensionProperties,
				 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
		log.info("Upgrading camera extension \(existing.bundleVersion, privacy: .public) → \(ext.bundleVersion, privacy: .public)")
		return .replace
	}

	func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
		log.warning("Camera extension needs user approval in System Settings")
		DispatchQueue.main.async { self.showApprovalNeededAlert() }
	}

	func request(_ request: OSSystemExtensionRequest,
				 didFinishWithResult result: OSSystemExtensionRequest.Result) {
		switch result {
		case .completed:
			log.info("Camera extension activated successfully")
		case .willCompleteAfterReboot:
			log.warning("Camera extension activation will complete after reboot (dirty system extension database)")
			DispatchQueue.main.async { self.showRebootRequiredAlert() }
		@unknown default:
			log.error("Camera extension finished with unknown result \(result.rawValue, privacy: .public)")
		}
	}

	func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
		let nsError = error as NSError
		// "Request superseded" just means a newer request was submitted — not an error.
		if nsError.domain == OSSystemExtensionErrorDomain,
		   nsError.code == OSSystemExtensionError.requestSuperseded.rawValue {
			log.info("Extension activation request superseded by newer request (OK)")
			return
		}
		log.error("Camera extension activation failed: \(error.localizedDescription, privacy: .public)")
		DispatchQueue.main.async { self.showActivationFailedAlert(error: error) }
	}

	// MARK: - NSApplicationDelegate

	private var previewWindows: [String: CameraPreviewWindowController] = [:]

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		activateExtension()
		migrateAgentIfNeeded { [weak self] in
			self?.installAndStartCameraAgent()
		}
		// Request camera access so this app bundle is registered in TCC and appears
		// in System Settings → Privacy & Security → Camera.
		AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
			self?.log.info("PtpWebcamApp: camera access \(granted ? "granted" : "denied", privacy: .public)")
		}
	}

	func applicationWillTerminate(_ aNotification: Notification) {}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

	// Keep app alive after all preview windows are closed so URL launches don't
	// re-run applicationDidFinishLaunching (which would restart the agent).
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	// Suppress Dock-click window restore — this app has no persistent main window.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }

	// MARK: - URL Scheme (ptpwebcam://preview?name=<camera>)

	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls where url.scheme == "ptpwebcam" && url.host == "preview" {
			guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
				  let name = components.queryItems?.first(where: { $0.name == "name" })?.value else { continue }
			openPreview(cameraName: name)
		}
	}

	private func openPreview(cameraName: String) {
		if let existing = previewWindows[cameraName] {
			existing.showWindow(nil)
			existing.window?.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}
		let controller = CameraPreviewWindowController(cameraName: cameraName)
		controller.onClose = { [weak self] in self?.previewWindows.removeValue(forKey: cameraName) }
		previewWindows[cameraName] = controller
		controller.showWindow(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	// MARK: - Extension Activation

	private func activateExtension() {
		let activationRequest = OSSystemExtensionRequest.activationRequest(
			forExtensionWithIdentifier: extensionIdentifier, queue: .main)
		activationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(activationRequest)
		log.info("Submitted camera extension activation request")
	}

	// MARK: - Migration from old launchctl mechanism

	/// If the agent was previously installed via the old launchctl mechanism (a hand-written
	/// plist in ~/Library/LaunchAgents/), remove that plist and bootout the old service so
	/// SMAppService can take clean ownership.  Calls completion when done (or if no migration needed).
	private func migrateAgentIfNeeded(completion: @escaping () -> Void) {
		let oldPlistPath = (NSHomeDirectory() as NSString)
			.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

		guard FileManager.default.fileExists(atPath: oldPlistPath) else {
			completion()
			return
		}

		log.info("Migrating from old launchctl agent — removing \(oldPlistPath, privacy: .public)")

		// Remove the old plist so launchd won't try to manage it anymore.
		do {
			try FileManager.default.removeItem(atPath: oldPlistPath)
			log.info("Old LaunchAgents plist removed")
		} catch {
			log.error("Failed to remove old plist: \(error.localizedDescription, privacy: .public)")
			// Proceed anyway — SMAppService will still try to take over.
		}

		// Bootout the running service so SMAppService gets a clean Mach namespace.
		let uid = String(getuid())
		let serviceTarget = "gui/\(uid)/\(agentLabel)"
		runProcess("/bin/launchctl", ["bootout", serviceTarget]) { exitCode in
			self.log.info("Migration bootout exit=\(exitCode, privacy: .public) (non-zero OK if not previously loaded)")
			// Brief delay to let the old process exit before SMAppService registers.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				completion()
			}
		}
	}

	// MARK: - Camera Agent Lifecycle

	/// Registers (or restarts) PtpCameraAgent via SMAppService agent(plistName:).
	/// On first launch the BTM has no record (.notFound) so we call register().
	/// On subsequent launches the agent is already .enabled, so we unregister and
	/// re-register to pick up any new binary (upgrade path).
	private func installAndStartCameraAgent() {
		let agentSvc = SMAppService.agent(plistName: agentPlistName)
		let agentStatus = agentSvc.status
		log.info("PtpCameraAgent agent status raw=\(agentStatus.rawValue, privacy: .public) (\(String(describing: agentStatus), privacy: .public))")
		handleServiceStatus(agentStatus, service: agentSvc, label: "agent")
	}

	private func handleServiceStatus(_ status: SMAppService.Status, service: SMAppService, label: String) {
		switch status {
		case .enabled:
			log.info("PtpCameraAgent \(label, privacy: .public) enabled, restarting for update...")
			service.unregister { [weak self] error in
				guard let self else { return }
				if let error {
					let nsErr = error as NSError
					self.log.error("PtpCameraAgent unregister failed: \(nsErr.domain, privacy: .public)/\(nsErr.code) — \(error.localizedDescription, privacy: .public)")
					return
				}
				self.log.info("PtpCameraAgent unregistered, re-registering...")
				self.doRegister(service: service, label: label)
			}
		case .notRegistered, .requiresApproval:
			if status == .requiresApproval {
				log.warning("PtpCameraAgent requires user approval in Login Items settings")
			}
			doRegister(service: service, label: label)
		case .notFound:
			// No BTM record yet — attempt registration so doRegister() surfaces any real error.
			log.info("PtpCameraAgent \(label, privacy: .public) has no system record, attempting register...")
			doRegister(service: service, label: label)
		@unknown default:
			log.error("PtpCameraAgent unknown status \(status.rawValue) via \(label, privacy: .public), attempting register")
			doRegister(service: service, label: label)
		}
	}

	private func doRegister(service: SMAppService, label: String) {
		do {
			try service.register()
			log.info("PtpCameraAgent registered via \(label, privacy: .public), status: \(String(describing: service.status), privacy: .public)")
		} catch {
			let nsErr = error as NSError
			log.error("PtpCameraAgent register via \(label, privacy: .public) failed: \(nsErr.domain, privacy: .public)/\(nsErr.code) — \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: - Process helper (for one-time migration bootout only)

	private func runProcess(_ executable: String, _ args: [String], completion: @escaping (Int32) -> Void) {
		DispatchQueue.global(qos: .utility).async {
			let task = Process()
			task.executableURL = URL(fileURLWithPath: executable)
			task.arguments = args
			task.standardOutput = FileHandle.nullDevice
			task.standardError = FileHandle.nullDevice
			do {
				try task.run()
				task.waitUntilExit()
				DispatchQueue.main.async { completion(task.terminationStatus) }
			} catch {
				self.log.error("Failed to run \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
				DispatchQueue.main.async { completion(-1) }
			}
		}
	}

	// MARK: - Alerts

	private func showApprovalNeededAlert() {
		let alert = NSAlert()
		alert.messageText = "Allow PTP Webcam in System Settings"
		alert.informativeText = "The camera extension needs your approval to activate.\n\nOpen System Settings → Privacy & Security, scroll to Security, and click \"Allow\" next to PTP Webcam Camera Extension."
		alert.addButton(withTitle: "Open System Settings")
		alert.addButton(withTitle: "Later")
		if alert.runModal() == .alertFirstButtonReturn {
			let url = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
			NSWorkspace.shared.open(url)
		}
	}

	private func showRebootRequiredAlert() {
		let alert = NSAlert()
		alert.messageText = "Restart Required"
		alert.informativeText = "A restart is needed to complete the camera extension upgrade. Please save your work and restart your Mac."
		alert.alertStyle = .warning
		alert.addButton(withTitle: "OK")
		alert.runModal()
	}

	private func showActivationFailedAlert(error: Error) {
		let alert = NSAlert()
		alert.messageText = "Camera Extension Could Not Activate"
		alert.informativeText = error.localizedDescription
		alert.alertStyle = .critical
		alert.addButton(withTitle: "OK")
		alert.runModal()
	}
}
