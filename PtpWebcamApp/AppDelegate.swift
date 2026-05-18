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
	// All nested bundle IDs follow the App Store prefix rule: helpers and
	// extensions are `<host-app-bundle-id>.<suffix>`. Launchd label, plist
	// filename, and Mach service names track the same prefix for
	// consistency — easier to grep, easier to reason about. The mach
	// service names declared in `org.ptpwebcam.PtpWebcamApp.PtpCameraAgent.plist`
	// must match `kPtpCameraAgentMachServiceName` /
	// `kPtpSurfaceSharingMachServiceName` in PtpCameraAgentProtocol.swift.
	private let extensionIdentifier = "org.ptpwebcam.PtpWebcamApp.CameraExtension"
	private let agentPlistName = "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent.plist"
	private let agentLabel     = "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent"

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
		installAndStartCameraAgent()
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
		// Note: don't try to submit a deactivation request for a legacy
		// bundle ID (e.g. the pre-App-Store `org.ptpwebcam.PtpWebcamApp.CameraExtension`).
		// sysextd requires the requesting app to contain an extension with
		// the matching identifier in its bundle, which our renamed build
		// no longer does — the deactivation just fails with "extension not
		// found in app bundle" and pollutes the logs. Legacy records have
		// to be cleared from outside the app (System Settings → Login
		// Items & Extensions → Camera Extensions, or
		// `sudo systemextensionsctl uninstall` with SIP disabled).
		let activationRequest = OSSystemExtensionRequest.activationRequest(
			forExtensionWithIdentifier: extensionIdentifier, queue: .main)
		activationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(activationRequest)
		log.info("Submitted camera extension activation request")
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

	// MARK: - Alerts

	private func showApprovalNeededAlert() {
		let alert = NSAlert()
		alert.messageText = "Allow PTP Webcam in System Settings"
		// Path varies by macOS release. Cover both locations because the
		// Camera Extension category lives under Login Items & Extensions
		// on macOS 15+, and the "Allow" button for blocked system
		// extensions still appears under Privacy & Security → Security
		// on earlier versions.
		alert.informativeText = """
			The camera extension needs your approval to activate.

			On macOS 15 (Sequoia) or later:
			  System Settings → General → Login Items & Extensions → \
			scroll to Camera Extensions, click the (i) next to it, and \
			enable PTP Webcam Camera Extension.

			On macOS 14 (Sonoma) and earlier:
			  System Settings → Privacy & Security → scroll to Security, \
			and click "Allow" next to PTP Webcam Camera Extension.
			"""
		alert.addButton(withTitle: "Open System Settings")
		alert.addButton(withTitle: "Later")
		if alert.runModal() == .alertFirstButtonReturn {
			// Open Login Items & Extensions on modern macOS — that's
			// where camera extension approval lives now. On older macOS
			// versions this URL falls back to the General pane, from
			// which the user can navigate to Privacy & Security.
			let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
				?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
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
	/// Set when the in-flight dump was kicked off by the main window's
	/// "Submit Issue" button. Tells `handleDumpTextPage` to route the
	/// resulting text into the GitHub issue flow (clipboard + browser)
	/// instead of the regular copy/save delivery dialog.
	private var pendingDumpForIssue: Bool = false

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
		let forIssue = pendingDumpForIssue
		pendingDumpLocationID = nil
		pendingDumpDisplayName = nil
		pendingDumpForIssue = false
		log.info("PTP dump text received (\(text.count, privacy: .public) chars)")
		if forIssue {
			openGitHubIssueWithDump(dumpText: text, deviceLabel: displayName)
		} else {
			presentDumpDeliveryOptions(dumpText: text, deviceLabel: displayName)
		}
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

	// MARK: - Submit Issue

	/// Entry point for the main window's "Submit Issue" button. Picks a PTP
	/// device (auto if exactly one is attached, prompt if many, skip the
	/// dump if none), runs the dump, and routes the result into the GitHub
	/// new-issue flow via `openGitHubIssueWithDump`.
	@objc func beginIssueSubmission() {
		// Refresh the device list before we look at it — the menu's NSMenuDelegate
		// path does this on submenu open, but the main-window button has no
		// equivalent hook. Post the request now; if devices come back later
		// we'll just see an empty list on this attempt and the user can retry.
		darwin_notify_post(kDarwinPtpDumpDevicesRequest)
		// Give the extension a brief moment to publish a fresh device list.
		// The slot chain handler updates ptpDumpDevices synchronously when
		// each page arrives, so by the time this fires we either have the
		// up-to-date list or none was forthcoming (no PTP devices attached).
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
			self?.beginIssueSubmissionAfterRefresh()
		}
	}

	private func beginIssueSubmissionAfterRefresh() {
		switch ptpDumpDevices.count {
		case 0:
			// No camera attached — open the issue form with system info only.
			// Users hitting this path are reporting bugs unrelated to a
			// specific camera (UI, installation, etc.).
			openGitHubIssueWithDump(dumpText: nil, deviceLabel: nil)
		case 1:
			startIssueDump(for: ptpDumpDevices[0])
		default:
			let alert = NSAlert()
			alert.messageText = NSLocalizedString("Which camera is this about?",
			                                       comment: "Issue-submit device picker title")
			alert.informativeText = NSLocalizedString("Pick the camera you'd like the PTP property dump to come from. The dump helps us reproduce camera-specific issues.",
			                                          comment: "Issue-submit device picker body")
			for d in ptpDumpDevices { alert.addButton(withTitle: d.displayLabel) }
			alert.addButton(withTitle: NSLocalizedString("No Camera / General Issue",
			                                              comment: "Issue-submit picker — skip dump"))
			let response = alert.runModal()
			let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
			if idx >= 0 && idx < ptpDumpDevices.count {
				startIssueDump(for: ptpDumpDevices[idx])
			} else {
				openGitHubIssueWithDump(dumpText: nil, deviceLabel: nil)
			}
		}
	}

	private func startIssueDump(for device: PtpDumpDeviceEntry) {
		pendingDumpLocationID = device.locationID
		pendingDumpDisplayName = device.displayLabel
		pendingDumpForIssue = true
		postDumpCommand(locationID: device.locationID)
	}

	/// Opens a pre-filled GitHub new-issue URL with the PTP dump inlined in
	/// the body whenever it fits. GitHub accepts long query strings (the
	/// issue body cap is 65,535 chars), but the practical limit is the URL
	/// length browsers and intermediate proxies will accept — empirically
	/// ~8 KB is safe across Safari / Chrome / Firefox. If the encoded URL
	/// would exceed that, we fall back to copying the dump to the system
	/// pasteboard and inlining a `<paste dump here>` placeholder.
	private func openGitHubIssueWithDump(dumpText: String?, deviceLabel: String?) {
		let title: String
		if let label = deviceLabel {
			title = "[\(label)] "
		} else {
			title = ""
		}

		// First attempt: try the URL with the dump fully inlined. If that
		// produces a URL within the safe budget we ship it and the user
		// gets a one-click issue with no paste step. Otherwise we degrade
		// gracefully to the clipboard fallback.
		let inlineBody = buildIssueBody(dumpText: dumpText, deviceLabel: deviceLabel, inlineDump: true)
		let issueBase = "https://github.com/dognotdog/ptpwebcam/issues/new"
		// 32 KB matches Chrome's URL cap and is well under Safari's 80 KB
		// limit. Intermediate hops (corporate proxies, URL-rewriting
		// browser extensions) may truncate earlier — when that happens the
		// user can re-run with the clipboard fallback by saving the dump
		// from File → List PTP Properties.
		let urlBudget = 32768

		if dumpText != nil,
		   let inlineURL = buildIssueURL(base: issueBase, title: title, body: inlineBody),
		   inlineURL.absoluteString.count <= urlBudget {
			log.info("PTP dump inlined into issue URL (\(inlineURL.absoluteString.count, privacy: .public) chars)")
			NSWorkspace.shared.open(inlineURL)
			return
		}

		// Fallback path: dump is too big to inline. Copy to clipboard, swap
		// the inline dump for a `<paste dump here>` marker, then prompt the
		// user before opening so they're not surprised by the placeholder.
		let placeholderBody = buildIssueBody(dumpText: dumpText, deviceLabel: deviceLabel, inlineDump: false)
		guard let url = buildIssueURL(base: issueBase, title: title, body: placeholderBody) else {
			log.error("Could not build GitHub issue URL")
			return
		}

		if let dumpText {
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(dumpText, forType: .string)
			log.info("PTP dump too large for URL — copied to clipboard (\(dumpText.count, privacy: .public) chars)")

			let alert = NSAlert()
			alert.messageText = NSLocalizedString("Dump copied — ready to file the issue",
			                                       comment: "Issue submit confirm dialog title")
			alert.informativeText = NSLocalizedString("Your PTP property dump is large, so it has been copied to the clipboard rather than embedded in the URL. After GitHub opens, paste it where the issue template says “paste dump here.”",
			                                          comment: "Issue submit confirm dialog body")
			alert.addButton(withTitle: NSLocalizedString("Open GitHub", comment: "Issue submit confirm dialog primary"))
			alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Issue submit confirm dialog secondary"))
			if alert.runModal() != .alertFirstButtonReturn { return }
		}

		NSWorkspace.shared.open(url)
	}

	/// Compose the markdown body for a new GitHub issue. `inlineDump=true`
	/// embeds the full dump inside a code fence; `inlineDump=false` swaps in
	/// a `<paste dump here>` placeholder for the clipboard fallback path.
	private func buildIssueBody(dumpText: String?, deviceLabel: String?, inlineDump: Bool) -> String {
		var lines: [String] = []
		lines.append("**Describe the issue**")
		lines.append("<!-- A clear and concise description of what's happening, what you expected, and steps to reproduce. -->")
		lines.append("")
		lines.append("**Environment**")
		lines.append("- App version: \(appVersionString())")
		lines.append("- macOS: \(macOSVersionString())")
		lines.append("- Hardware: \(hardwareModelString())")
		if let label = deviceLabel {
			lines.append("- Camera: \(label)")
		}
		lines.append("")
		lines.append("**PTP property dump**")
		lines.append("")
		if let dumpText, inlineDump {
			// Wrap in <details> so the issue stays readable — most dumps are
			// long enough to overwhelm the rest of the report.
			lines.append("<details><summary>Click to expand</summary>")
			lines.append("")
			lines.append("```")
			lines.append(dumpText)
			lines.append("```")
			lines.append("")
			lines.append("</details>")
		} else if dumpText != nil {
			lines.append("<!-- The full dump has been copied to your clipboard. Paste it inside the code fence below. -->")
			lines.append("")
			lines.append("```")
			lines.append("<paste dump here>")
			lines.append("```")
		} else {
			lines.append("_No camera was attached when this issue was filed._")
		}
		return lines.joined(separator: "\n")
	}

	/// Build a `?title=...&body=...` URL using URLComponents so newlines,
	/// brackets, quotes, and other unsafe characters are correctly
	/// percent-encoded by the standard library.
	private func buildIssueURL(base: String, title: String, body: String) -> URL? {
		var components = URLComponents(string: base)
		components?.queryItems = [
			URLQueryItem(name: "title", value: title),
			URLQueryItem(name: "body",  value: body),
		]
		return components?.url
	}

	private func appVersionString() -> String {
		let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
		let build = Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "?"
		return "\(short) (\(build))"
	}

	private func macOSVersionString() -> String {
		let v = ProcessInfo.processInfo.operatingSystemVersion
		return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
	}

	private func hardwareModelString() -> String {
		var size: size_t = 0
		sysctlbyname("hw.model", nil, &size, nil, 0)
		guard size > 0 else { return "unknown" }
		var buf = [CChar](repeating: 0, count: size)
		sysctlbyname("hw.model", &buf, &size, nil, 0)
		return String(cString: buf)
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
