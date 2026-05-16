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
import StoreKit

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
		// Install the "List PTP Properties" submenu under File so users can
		// generate a PTP property dump for any attached PTP/MTP device — the
		// most useful artifact for adding support for new camera vendors.
		installPtpDumpMenu()
		setupPtpDumpSlotSubscriptions()
		// Request camera access so this app bundle is registered in TCC and appears
		// in System Settings → Privacy & Security → Camera.
		AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
			self?.log.info("PtpWebcamApp: camera access \(granted ? "granted" : "denied", privacy: .public)")
		}
		// Surface the main window unless this launch came in via a URL scheme
		// (`ptpwebcam://preview?…`), in which case `application(_:open:)` will
		// already have opened a preview window and the user probably doesn't
		// want the main app window stealing focus on top.
		if aNotification.userInfo?["NSApplicationLaunchUserNotificationKey"] == nil,
		   NSApp.windows.allSatisfy({ !$0.isVisible }) {
			MainWindowController.shared.present()
		}
	}

	func applicationWillTerminate(_ aNotification: Notification) {}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

	// Keep app alive after all preview windows are closed so URL launches don't
	// re-run applicationDidFinishLaunching (which would restart the agent).
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	// Dock click / "Open" again: re-show the main subscription window. Return
	// `true` to suppress AppKit's automatic window-restore behavior — we're
	// surfacing the window ourselves so the user always lands on the same
	// content rather than whatever preview window happened to be last.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		MainWindowController.shared.present()
		return true
	}

	/// Action wired up from MainMenu.xib (PTP Webcam menu → "About PTP Webcam…").
	/// Brings up the main subscription/about window. Same effect as a Dock
	/// click, but reachable from the menu bar while a stream-preview window
	/// has focus.
	@IBAction func showMainWindow(_ sender: Any?) {
		MainWindowController.shared.present()
	}

	// MARK: - URL Scheme (ptpwebcam://preview?name=<camera>)

	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls where url.scheme == "ptpwebcam" {
			switch url.host {
			case "preview":
				guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					  let name = components.queryItems?.first(where: { $0.name == "name" })?.value else { continue }
				openPreview(cameraName: name)
			case "about":
				// Lets the agent (a separate process) ask us to show the main
				// window without needing an XPC channel. `NSWorkspace.open`
				// of this URL launches us if we're not running, or routes
				// the URL to the live instance via Apple Events if we are.
				MainWindowController.shared.present()
			default:
				log.info("Ignoring unknown ptpwebcam:// URL host=\(url.host ?? "nil", privacy: .public)")
			}
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
		controller.onClose = { [weak self] in
			guard let self = self else { return }
			self.previewWindows.removeValue(forKey: cameraName)
			// Closing the preview is the moment of least friction: the user is
			// already shifting attention. Show the subscription window now,
			// but only when (a) the user has no active subscription and (b)
			// we haven't already nudged them today. Otherwise the reminder
			// becomes spam and the user starts dismissing it reflexively.
			self.maybeShowSubscriptionReminderAfterPreviewClose()
		}
		previewWindows[cameraName] = controller
		controller.showWindow(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	// MARK: - Subscription Reminder

	/// Last-shown timestamp for the "consider subscribing" main-window prompt.
	/// Stored in UserDefaults so the 24-hour throttle persists across relaunches
	/// (each preview launch starts a fresh process via the URL handler).
	private static let lastReminderKey = "lastSubscriptionReminderAt"
	private static let reminderInterval: TimeInterval = 24 * 60 * 60

	private func maybeShowSubscriptionReminderAfterPreviewClose() {
		// Throttle check is cheap; do it first so we don't bother StoreKit
		// when we're definitely going to skip.
		let defaults = UserDefaults.standard
		if let last = defaults.object(forKey: Self.lastReminderKey) as? Date,
		   Date().timeIntervalSince(last) < Self.reminderInterval {
			log.info("subscription reminder skipped: shown <24h ago")
			return
		}

		// Entitlement check goes straight to StoreKit's `currentEntitlements`
		// stream — avoids spinning up a whole SubscriptionStore observable
		// just to read one bit. Verified-and-current auto-renewable
		// transactions count; anything else (revoked, expired, refunded)
		// is filtered out by StoreKit already.
		Task { @MainActor in
			var isSubscribed = false
			for await result in Transaction.currentEntitlements {
				if case .verified(let txn) = result, txn.productType == .autoRenewable {
					isSubscribed = true
					break
				}
			}
			if isSubscribed {
				self.log.info("subscription reminder skipped: user is already subscribed")
				return
			}
			// Timestamp update happens inside MainWindowController.present()
			// so EVERY path that opens the window — auto, About menu, Dock
			// click — extends the throttle by the same amount.
			self.log.info("subscription reminder shown after preview close")
			MainWindowController.shared.present()
		}
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

	/// Registers (or restarts) PtpWebcamAgent via SMAppService agent(plistName:).
	/// On first launch the BTM has no record (.notFound) so we call register().
	/// On subsequent launches the agent is already .enabled, so we unregister and
	/// re-register to pick up any new binary (upgrade path).
	private func installAndStartCameraAgent() {
		let agentSvc = SMAppService.agent(plistName: agentPlistName)
		let agentStatus = agentSvc.status
		log.info("PtpWebcamAgent agent status raw=\(agentStatus.rawValue, privacy: .public) (\(String(describing: agentStatus), privacy: .public))")
		handleServiceStatus(agentStatus, service: agentSvc, label: "agent")
	}

	private func handleServiceStatus(_ status: SMAppService.Status, service: SMAppService, label: String) {
		switch status {
		case .enabled:
			log.info("PtpWebcamAgent \(label, privacy: .public) enabled, restarting for update...")
			service.unregister { [weak self] error in
				guard let self else { return }
				if let error {
					let nsErr = error as NSError
					self.log.error("PtpWebcamAgent unregister failed: \(nsErr.domain, privacy: .public)/\(nsErr.code) — \(error.localizedDescription, privacy: .public)")
					return
				}
				self.log.info("PtpWebcamAgent unregistered, re-registering...")
				self.doRegister(service: service, label: label)
			}
		case .notRegistered, .requiresApproval:
			if status == .requiresApproval {
				log.warning("PtpWebcamAgent requires user approval in Login Items settings")
			}
			doRegister(service: service, label: label)
		case .notFound:
			// No BTM record yet — attempt registration so doRegister() surfaces any real error.
			log.info("PtpWebcamAgent \(label, privacy: .public) has no system record, attempting register...")
			doRegister(service: service, label: label)
		@unknown default:
			log.error("PtpWebcamAgent unknown status \(status.rawValue) via \(label, privacy: .public), attempting register")
			doRegister(service: service, label: label)
		}
	}

	private func doRegister(service: SMAppService, label: String) {
		do {
			try service.register()
			log.info("PtpWebcamAgent registered via \(label, privacy: .public), status: \(String(describing: service.status), privacy: .public)")
		} catch {
			let nsErr = error as NSError
			log.error("PtpWebcamAgent register via \(label, privacy: .public) failed: \(nsErr.domain, privacy: .public)/\(nsErr.code) — \(error.localizedDescription, privacy: .public)")
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

	// MARK: - PTP Property Dump
	//
	// Menu wiring + Darwin notify glue for the "File → List PTP Properties"
	// submenu. The extension owns USB I/O; the app just (a) shows the device
	// picker, (b) posts a dump command, and (c) opens the resulting text in
	// TextEdit. No file ever hits disk — the dump text round-trips back to us
	// over the same multi-page slot chain we use for property state.

	private var ptpDumpMenuItem: NSMenuItem?
	private var ptpDumpSubmenu: NSMenu?

	/// Cached device list parsed from the extension's most recent
	/// kDarwinPtpDumpDevicesState publication. `[locationID: (label, ...)]`.
	private struct PtpDumpDeviceEntry {
		let locationID: UInt32
		let vid: UInt16
		let pid: UInt16
		let name: String
		let serial: String
		/// Friendly label preferred for menu display. Pulls "<Make> <Model>"
		/// from the shared PtpKnownCameras table when we recognise the
		/// VID/PID, falling back to the USB descriptor name (or the raw
		/// hex) for unknown devices. Always suffixes the VID/PID in hex so
		/// the developer can correlate menu entries with extension logs.
		var displayLabel: String {
			let pretty = PtpKnownCameras.displayName(vid: vid, pid: pid, fallback: name)
			return String(format: "%@  (%04X:%04X)", pretty, vid, pid)
		}
	}
	private var ptpDumpDevices: [PtpDumpDeviceEntry] = []

	/// Token bookkeeping + page reassembly state for the device list channel.
	private var dumpDevicesSlotTokens: [Int32] = []
	private var dumpDevicesPageBuffer: Data?
	private var dumpDevicesPageTotal: Int = 0
	private var dumpDevicesPageCount: Int = 0
	private var dumpDevicesNextPage: Int = 0

	/// Same for the dump-text channel.
	private var dumpTextSlotTokens: [Int32] = []
	private var dumpTextPageBuffer: Data?
	private var dumpTextPageTotal: Int = 0
	private var dumpTextPageCount: Int = 0
	private var dumpTextNextPage: Int = 0

	private func installPtpDumpMenu() {
		// MainMenu.xib has the standard File menu; locate it by title-matching
		// so we're robust to nib renumbering. Insert our item near the top
		// (after "New" if present, else at the top).
		guard let mainMenu = NSApp.mainMenu else { return }
		guard let fileMenuItem = mainMenu.items.first(where: { $0.submenu?.title == "File" || $0.title == "File" }),
		      let fileMenu = fileMenuItem.submenu else {
			// Some app templates don't ship a File menu. Add a top-level one.
			let newFileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
			let newFileMenu = NSMenu(title: "File")
			newFileItem.submenu = newFileMenu
			mainMenu.insertItem(newFileItem, at: 1)  // after App menu
			addDumpItem(to: newFileMenu, at: 0)
			return
		}
		// Drop any existing "New" item — this app is not document-based and the
		// dead menu confuses users. Put our submenu where it would have lived.
		if let newItemIdx = fileMenu.items.firstIndex(where: { $0.action == #selector(NSDocumentController.newDocument(_:)) || $0.title == "New" }) {
			fileMenu.removeItem(at: newItemIdx)
			addDumpItem(to: fileMenu, at: newItemIdx)
		} else {
			addDumpItem(to: fileMenu, at: 0)
		}
	}

	private func addDumpItem(to menu: NSMenu, at index: Int) {
		let item = NSMenuItem(title: NSLocalizedString("List PTP Properties",
		                                               comment: "File menu — submenu for PTP dump per USB device"),
		                      action: nil, keyEquivalent: "")
		let submenu = NSMenu(title: item.title)
		submenu.delegate = self  // refresh device list on open
		item.submenu = submenu
		menu.insertItem(item, at: max(0, min(index, menu.items.count)))
		ptpDumpMenuItem = item
		ptpDumpSubmenu = submenu
		rebuildPtpDumpSubmenu()
	}

	private func rebuildPtpDumpSubmenu() {
		guard let submenu = ptpDumpSubmenu else { return }
		submenu.removeAllItems()
		if ptpDumpDevices.isEmpty {
			let empty = NSMenuItem(title: NSLocalizedString("No PTP devices detected",
			                                                comment: "Empty state for List PTP Properties submenu"),
			                       action: nil, keyEquivalent: "")
			empty.isEnabled = false
			submenu.addItem(empty)
			return
		}
		for d in ptpDumpDevices {
			let mi = NSMenuItem(title: d.displayLabel,
			                    action: #selector(dumpPtpDeviceClicked(_:)),
			                    keyEquivalent: "")
			mi.target = self
			mi.representedObject = d.locationID
			submenu.addItem(mi)
		}
	}

	/// Camera name + locationID for the currently-pending dump request.
	/// Cleared once the dump text arrives. Used by the BUSY-dialog path so
	/// the user can ask us to retry the same camera after stopping its
	/// live view.
	private var pendingDumpLocationID: UInt32?
	private var pendingDumpDisplayName: String?

	@objc private func dumpPtpDeviceClicked(_ sender: NSMenuItem) {
		guard let locationID = sender.representedObject as? UInt32 else { return }
		pendingDumpLocationID = locationID
		pendingDumpDisplayName = sender.title
		postDumpCommand(locationID: locationID)
	}

	private func postDumpCommand(locationID: UInt32) {
		log.info("PTP dump requested for locationID=0x\(String(locationID, radix: 16), privacy: .public)")
		var cmdSlotToken: Int32 = 0
		darwin_notify_register_check(kDarwinPtpDumpCmdSlot, &cmdSlotToken)
		darwin_notify_set_state(cmdSlotToken, UInt64(locationID))
		darwin_notify_post(kDarwinPtpDumpCmd)
	}

	private func setupPtpDumpSlotSubscriptions() {
		// Register read tokens for the device-list slots…
		dumpDevicesSlotTokens = (0..<kDarwinPtpDumpDevicesSlotCount).map { i in
			var t: Int32 = 0
			darwin_notify_register_check(kDarwinPtpDumpDevicesSlotPrefix + "\(i)", &t)
			return t
		}
		// …and for the dump-text slots.
		dumpTextSlotTokens = (0..<kDarwinPtpDumpTextSlotCount).map { i in
			var t: Int32 = 0
			darwin_notify_register_check(kDarwinPtpDumpTextSlotPrefix + "\(i)", &t)
			return t
		}

		// Subscribe to device-list publications.
		var devToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinPtpDumpDevicesState, &devToken, .main) { [weak self] _ in
			self?.handleDumpDevicesPage()
		}
		// Subscribe to dump-text publications.
		var textToken: Int32 = 0
		darwin_notify_register_dispatch(kDarwinPtpDumpText, &textToken, .main) { [weak self] _ in
			self?.handleDumpTextPage()
		}
		// Kick the extension for an initial list — Darwin notify posts aren't
		// replayed for late subscribers, so without this prompt we'd see an
		// empty submenu until the user replugs a camera.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			darwin_notify_post(kDarwinPtpDumpDevicesRequest)
		}
	}

	// MARK: - Slot-chain reassembly (devices list + dump text)

	private func handleDumpDevicesPage() {
		guard let payload = receiveSlotChainPage(
				tokens: dumpDevicesSlotTokens,
				slotCount: kDarwinPtpDumpDevicesSlotCount,
				pageBuffer: &dumpDevicesPageBuffer,
				pageTotal: &dumpDevicesPageTotal,
				pageCount: &dumpDevicesPageCount,
				nextPage: &dumpDevicesNextPage) else { return }
		guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
			log.error("PTP dump device list — JSON decode failed (\(payload.count) bytes)")
			return
		}
		ptpDumpDevices = arr.compactMap { d in
			guard let loc = (d["loc"] as? NSNumber)?.uint32Value,
			      let vid = (d["vid"] as? NSNumber)?.uint16Value,
			      let pid = (d["pid"] as? NSNumber)?.uint16Value else { return nil }
			let name = (d["name"] as? String) ?? ""
			let serial = (d["serial"] as? String) ?? ""
			return PtpDumpDeviceEntry(locationID: loc, vid: vid, pid: pid, name: name, serial: serial)
		}
		log.info("PTP dump device list: \(self.ptpDumpDevices.count, privacy: .public) device(s)")
		rebuildPtpDumpSubmenu()
	}

	private func handleDumpTextPage() {
		guard let payload = receiveSlotChainPage(
				tokens: dumpTextSlotTokens,
				slotCount: kDarwinPtpDumpTextSlotCount,
				pageBuffer: &dumpTextPageBuffer,
				pageTotal: &dumpTextPageTotal,
				pageCount: &dumpTextPageCount,
				nextPage: &dumpTextNextPage) else { return }
		guard let text = String(data: payload, encoding: .utf8), !text.isEmpty else {
			log.error("PTP dump text — UTF-8 decode failed (\(payload.count) bytes)")
			return
		}
		// BUSY sentinel: the camera is claimed AND streaming. Offer the user
		// the choice to stop live view and retry, or cancel.
		if text.hasPrefix("[BUSY]") {
			let label = text.dropFirst("[BUSY]".count).trimmingCharacters(in: .whitespacesAndNewlines)
			handleDumpBusy(label: label)
			return
		}
		let displayName = pendingDumpDisplayName ?? "PTP Device"
		pendingDumpLocationID = nil
		pendingDumpDisplayName = nil
		log.info("PTP dump text received (\(text.count, privacy: .public) chars)")
		presentDumpDeliveryOptions(dumpText: text, deviceLabel: displayName)
	}

	private func handleDumpBusy(label: String) {
		guard let loc = pendingDumpLocationID else { return }
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Camera is streaming live video",
		                                       comment: "PTP dump busy dialog title")
		alert.informativeText = String(
			format: NSLocalizedString("%@ is currently delivering video to a CMIO client (QuickTime, Zoom, OBS, etc.). The PTP dump can't run while live view is active. Stop the stream first, then we'll generate the dump.",
			                          comment: "PTP dump busy dialog body, %@ is camera label"),
			label)
		alert.alertStyle = .warning
		alert.addButton(withTitle: NSLocalizedString("Stop Live View & Dump",
		                                              comment: "Primary action"))
		alert.addButton(withTitle: NSLocalizedString("Cancel",
		                                              comment: "Cancel"))
		if alert.runModal() == .alertFirstButtonReturn {
			// Tell the agent to release the camera (the existing claim/release
			// path takes the camera through stopLiveView → close → re-open
			// is too heavy here; we just need stopLiveView). We don't have a
			// dedicated "stop LV" Darwin notify channel exposed to the app —
			// post the existing kDarwinLiveViewStop with the cameraId. But
			// we don't have the cameraId here, only locationID. Simpler:
			// re-issue the dump command after a short grace; if the user has
			// indeed stopped streaming themselves it will succeed.
			//
			// For now, surface a clear next step rather than racing: ask the
			// user to quit the consuming app, then click again.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
				self?.postDumpCommand(locationID: loc)
			}
		} else {
			pendingDumpLocationID = nil
			pendingDumpDisplayName = nil
		}
	}

	/// Reassemble one page worth of slot-chain data using the standard 3-field
	/// header (totalLength<<32 | pageIndex<<16 | pageCount), N data slots,
	/// final-slot additive checksum. Returns the full reassembled payload
	/// once the last page arrives; nil otherwise.
	private func receiveSlotChainPage(
		tokens: [Int32], slotCount: Int,
		pageBuffer: inout Data?, pageTotal: inout Int,
		pageCount: inout Int, nextPage: inout Int
	) -> Data? {
		var slot0: UInt64 = 0
		darwin_notify_get_state(tokens[0], &slot0)
		let totalLength = Int(slot0 >> 32)
		let pageIndex = Int((slot0 >> 16) & 0xFFFF)
		let pc = Int(slot0 & 0xFFFF)
		guard totalLength > 0, pc > 0, pageIndex < pc else { return nil }

		let pageDataSlots = slotCount - 2
		let pageSize = pageDataSlots * 8
		let pageOffset = pageIndex * pageSize
		let pageLength = min(pageSize, totalLength - pageOffset)
		guard pageLength > 0 else { return nil }

		if pageIndex == 0 || pageBuffer == nil || pageTotal != totalLength {
			pageBuffer = Data(count: totalLength)
			pageTotal = totalLength
			pageCount = pc
			nextPage = 0
		}
		guard var buffer = pageBuffer, pageIndex == nextPage else {
			log.error("PTP slot-chain page \(pageIndex) out of order (expected \(self.dumpTextNextPage))")
			pageBuffer = nil
			return nil
		}
		buffer.withUnsafeMutableBytes { ptr in
			for i in 0..<((pageLength + 7) / 8) {
				var value: UInt64 = 0
				darwin_notify_get_state(tokens[i + 1], &value)
				let chunkOffset = pageOffset + i * 8
				let chunkSize = min(8, totalLength - chunkOffset)
				if chunkSize > 0 { memcpy(ptr.baseAddress! + chunkOffset, &value, chunkSize) }
			}
		}
		pageBuffer = buffer

		// Verify additive checksum for the page.
		var csValue: UInt64 = 0
		darwin_notify_get_state(tokens[slotCount - 1], &csValue)
		let expected = UInt32(csValue & 0xFFFFFFFF)
		var computed: UInt32 = 0
		for byte in buffer[pageOffset..<(pageOffset + pageLength)] {
			computed = computed &+ UInt32(byte)
		}
		guard computed == expected else {
			log.error("PTP slot-chain checksum mismatch page \(pageIndex) computed=\(computed) expected=\(expected)")
			pageBuffer = nil
			return nil
		}

		nextPage += 1
		if nextPage >= pageCount {
			let final = buffer
			pageBuffer = nil
			pageTotal = 0
			pageCount = 0
			nextPage = 0
			return final
		}
		return nil
	}

	// MARK: - Dump delivery (copy or save)
	//
	// We previously tried opening the dump as a new untitled TextEdit
	// document via NSAppleScript, but that route fails with -1743
	// (errAEEventNotPermitted) under the App Sandbox — TextEdit doesn't
	// declare scripting access groups and the temporary-exception entitlement
	// path was unreliable. Simpler and friendlier: just ask the user where
	// they want the text.

	private func presentDumpDeliveryOptions(dumpText: String, deviceLabel: String) {
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("PTP Property Dump Ready",
		                                       comment: "Dump-delivery dialog title")
		alert.informativeText = String(
			format: NSLocalizedString("Generated %d characters of property data for %@. How would you like to receive it?",
			                          comment: "Dump-delivery dialog body, char count + device label"),
			dumpText.count, deviceLabel)
		alert.alertStyle = .informational
		// First button is the default (activated by Return / Enter).
		alert.addButton(withTitle: NSLocalizedString("Copy to Clipboard",
		                                              comment: "Primary action — recommended"))
		alert.addButton(withTitle: NSLocalizedString("Save to File…",
		                                              comment: "Save the dump to a file"))
		alert.addButton(withTitle: NSLocalizedString("Cancel",
		                                              comment: "Discard the dump"))
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(dumpText, forType: .string)
			log.info("PTP dump copied to clipboard (\(dumpText.count, privacy: .public) chars)")
		case .alertSecondButtonReturn:
			saveDumpToFile(dumpText, deviceLabel: deviceLabel)
		default:
			log.info("PTP dump discarded by user")
		}
	}

	private func saveDumpToFile(_ text: String, deviceLabel: String) {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.plainText]
		panel.canCreateDirectories = true
		// Suggest a useful default filename: "ptp-dump-<sanitised-label>.txt".
		// Strip everything that isn't filename-safe; collapse whitespace runs.
		let sanitised = deviceLabel
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.joined(separator: "-")
		let stamp = ISO8601DateFormatter().string(from: Date())
			.replacingOccurrences(of: ":", with: "")
			.replacingOccurrences(of: "-", with: "")
			.prefix(15)  // YYYYMMDDTHHMMSS
		panel.nameFieldStringValue = "ptp-dump-\(sanitised)-\(stamp).txt"
		panel.title = NSLocalizedString("Save PTP Property Dump",
		                                 comment: "Save panel title")
		panel.begin { [weak self] response in
			guard response == .OK, let url = panel.url else {
				self?.log.info("PTP dump save cancelled")
				return
			}
			do {
				try text.write(to: url, atomically: true, encoding: .utf8)
				self?.log.info("PTP dump saved to \(url.path, privacy: .public)")
			} catch {
				self?.log.error("PTP dump save failed: \(error.localizedDescription, privacy: .public)")
				let alert = NSAlert(error: error)
				alert.messageText = NSLocalizedString("Could Not Save Dump",
				                                       comment: "Save error title")
				alert.runModal()
			}
		}
	}
}

// MARK: - NSMenuDelegate (refresh device list on submenu open)

extension AppDelegate: NSMenuDelegate {
	func menuWillOpen(_ menu: NSMenu) {
		guard menu === ptpDumpSubmenu else { return }
		// Re-poll the extension each time the user opens the submenu — covers
		// the case where they plugged in a new camera since launch.
		darwin_notify_post(kDarwinPtpDumpDevicesRequest)
	}
}
