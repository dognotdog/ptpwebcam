# PTP Webcam — macOS 13+ Architecture

This documents the CMIOExtension-based architecture (macOS 13+) that replaces
the deprecated CoreMediaIO DAL plugin.  The old DAL plugin code in
`PtpWebcamDalPlugin/` is kept side-by-side for older macOS versions.

## Targets

| Target | Bundle ID | Role |
|--------|-----------|------|
| **PtpWebcamApp** | `org.ptpwebcam.PtpWebcamApp` | Host app. Installs the system extension and registers the launch agent. |
| **PtpCameraAgent** | `org.ptpwebcam.PtpWebcamApp.PtpCameraAgent` | Background helper (launchd agent). Detects USB PTP cameras via `ICDeviceBrowser`. Publishes camera state to the extension via Darwin notify. |
| **PtpWebcamCameraExtension** | `org.ptpwebcam.PtpWebcamApp.CameraExtension` | CMIOExtension system extension. Runs as `_cmiodalassistants` (UID 262). Exposes cameras to apps via `AVCaptureDevice`. |

## How the pieces connect

```
┌──────────────┐  Darwin notify   ┌──────────────────────┐   AVCaptureDevice
│ PtpCameraAgent│ ───────────────> │ CameraExtension      │ ──────────────> Apps
│ (user agent)  │  state slots     │ (_cmiodalassistants)  │
│               │ <─── request ─── │                       │
└──────┬───────┘                  └──────────────────────┘
       │ ICDeviceBrowser
       ▼
   USB PTP cameras
```

**IPC**: The extension runs in a sandbox under a different user, so neither
XPC Mach services nor `DistributedNotificationCenter` work across the
boundary.  Instead, we use **Darwin notify** (`notify.h`) with
`notify_set_state`/`notify_get_state` to pass a JSON camera list through
kernel-level 64-bit state slots.  See `DarwinNotify.swift` and
`PtpCameraAgentProtocol.swift` for the protocol constants.

**Launch agent**: `PtpCameraAgent` is registered as a launchd agent via
`org.ptpwebcam.PtpCameraAgent.plist` (bundled inside the app at
`Contents/Resources/PtpCameraAgent.app`).  It has `KeepAlive = true` so
launchd restarts it automatically.

## Building

### Prerequisites

- Xcode with a valid Apple Development signing identity
- `systemextensionsctl developer on` (run once; enables extension development)
- Team ID `ZYF8X9Z6M2` (or change `DEVELOPMENT_TEAM` in the build command)

### Command-line build

```sh
xcodebuild \
  -project "PTP Webcam.xcodeproj" \
  -target PtpWebcamApp \
  -configuration Debug \
  build \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=ZYF8X9Z6M2 \
  CURRENT_PROJECT_VERSION=<N>
```

This builds all three targets (the app embeds both the agent and the
extension).  The app is installed to `/Applications/PtpWebcamApp.app`.

**Important**: bump `CURRENT_PROJECT_VERSION` for each build that changes the
extension.  macOS uses this version to decide whether to replace the running
extension binary.

### Install script

```sh
./scripts/reinstall-extension.sh          # auto-increments version
./scripts/reinstall-extension.sh 10       # explicit version
./scripts/reinstall-extension.sh --reset  # wipe extension DB (forces re-approval)
```

The script kills running processes, builds, and relaunches the app.
**First time only**: you must approve the extension in
*System Settings > General > Login Items & Extensions > Camera Extensions*.
Subsequent version bumps upgrade in place without re-approval (as long as
`--reset` is not used).

### Verifying

```sh
# Extension is activated?
systemextensionsctl list

# Extension process running?
ps aux | grep CameraExtension | grep -v grep

# Agent running and detecting cameras?
cat /tmp/PtpCameraAgent.log

# Extension receiving camera state?
/usr/bin/log show --last 30s \
  --predicate 'subsystem == "org.ptpwebcam"' \
  --style compact

# Camera visible to apps?
swift -e 'import AVFoundation; let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices; for dev in d { print(dev.localizedName) }'
```

## Key files

| File | Purpose |
|------|---------|
| `PtpWebcamApp/AppDelegate.swift` | Submits `OSSystemExtensionRequest`, registers launch agent via `SMAppService` |
| `PtpWebcamApp/org.ptpwebcam.PtpCameraAgent.plist` | Launchd plist for the agent (KeepAlive, MachServices) |
| `PtpCameraAgent/AppDelegate.swift` | ICDeviceBrowser, Darwin notify state publishing |
| `PtpCameraAgent/DarwinNotify.swift` | `@_silgen_name` wrappers for `notify.h` C functions |
| `PtpCameraAgent/PtpCameraAgentProtocol.swift` | Shared constants (notification names, state slot config) |
| `PtpWebcamCameraExtension/PtpWebcamCameraExtensionProvider.swift` | CMIOExtension provider, device/stream sources, Darwin notify reader |
| `PtpWebcamCameraExtension/DarwinNotify.swift` | Same `@_silgen_name` wrappers (copy, kept in sync) |
| `PtpWebcamCameraExtension/PtpCameraAgentProtocol.swift` | Same shared constants (copy, kept in sync) |
| `scripts/reinstall-extension.sh` | Build + upgrade automation |

## Sandbox constraints

The CMIOExtension runs sandboxed as `_cmiodalassistants`.  Key limitations:

- Cannot read/write `/tmp/` or arbitrary filesystem paths
- `DistributedNotificationCenter` notifications are not delivered
- XPC Mach services from the per-user bootstrap are not visible
- `NSLog` output does not appear in unified logging; use `Logger.fault()` level
- Darwin notifications (`notify.h`) work across the sandbox boundary

## Debugging tips

- **Extension not starting**: check `registerassistantservice` logs:
  `/usr/bin/log show --last 60s --predicate 'process == "com.apple.cmio.registerassistantservice"' --style compact`
- **Launchd race condition on upgrade**: if the old extension process won't
  die, a reboot clears it.  Or use `--reset` (but you'll need to re-approve).
- **Agent not running**: `launchctl list | grep ptpwebcam`.  Check that
  `KeepAlive` is set in the plist.
- **Simulated camera**: in Debug builds, the agent adds a "Simulated Nikon
  D800" after 2 seconds, useful for testing without hardware.
