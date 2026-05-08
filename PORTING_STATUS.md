# CMIOExtension Port — Status

## Goal
Port the old Obj-C DAL plugin camera control (PtpCamera + vendor subclasses + agent menu)
to the new Swift CMIOExtension architecture under `PtpCameraAgent/`.

## Completed

### PtpCamera.swift (base class)
- PTP protocol handling (command building, parsing, send/receive)
- PtpDataParser for standard PTP data types
- PtpPropertyInfo struct with dataType (UInt32), writable, range, incremental, button flags
- Camera registry with factory method `PtpCamera.cameraForDevice()`
- Non-advertised operations table
- Subclass-overridable: `uiProperties`, `currentUiProperties`, `propertyValueNames`,
  `propertyNames`, `formatValue()`, `deviceInfoReceived()`, `receivedProperty()`,
  `handleCommand()`, `handlePtpEvent()`, `canAutofocus`, `performAutofocus()`
- ICCameraDeviceDelegate conformance (all required methods)
- PtpCameraDelegate protocol for AppDelegate callbacks

### PtpCameraNikon.swift
- 40+ camera registrations (vendor 0x04B0)
- Non-advertised ops for D3200, D3300, D3500
- Vendor property discovery (GETVENDORPROPS 0x90CA / GETVENDORCODES 0x9439)
- Readiness tracking (LV_SELECTOR, LV_IMAGESIZE, LV_PROHIBIT)
- Still/movie UI property filtering via LV_SELECTOR
- Nikon fraction shutter speed formatting (nom<<16|denom)
- WB tune, color temp, LV status formatting
- Autofocus via AFDRIVE (0x90C1)

### PtpCameraCanon.swift
- 46+ camera registrations (vendor 0x04A9)
- SETREMOTEMODE + SETEVENTMODE init handshake
- GETEVENT polling (1-second timer)
- Canon event block parsing (PROPVALCHANGED, AVAILLISTCHANGED)
- EOS 4-byte-padded data type reading/writing
- Canon-specific aperture/ISO/shutter speed logarithmic encoding
- SETPROPVAL_EX with property block encoding
- REQUESTPROPVAL for vendor property queries
- Autofocus via DOAF (0x9154)

### PtpCameraSony.swift
- 15 camera registrations (vendor 0x054C)
- Multi-step connect handshake (CONNECT 1→2→GETPROPERTIES→3→GETALLPROPDATA)
- GetAllPropertyData bulk parsing (proprietary format with flags/readwrite bytes)
- Incremental property setting (SETPROPSTEP 0x9207) vs absolute (SETPROPABS 0x9205)
- Button-style properties (AF button press/release)
- Sony shutter speed formatting, battery level, WB tune
- PTP event handling for SONY_PROPVALCHANGED (0xC203)

### AppDelegate.swift
- Updated to use `PtpCamera.cameraForDevice()` factory method
- Uses `camera.currentUiProperties` for menu ordering
- Uses `camera.formatValue(_:forProperty:)` and `camera.displayName(forProperty:)` for display
- Status bar menu with property submenus for writable enum/range properties
- Darwin notify state publishing, XPC listener, ICDeviceBrowser
- Simulated camera in DEBUG builds

### Supporting files (from prior sessions)
- DarwinNotify.swift — `@_silgen_name` wrappers for notify.h
- PtpCameraAgentProtocol.swift — shared constants, XPC protocols

### Build now passing ✓
All three vendor subclass Swift files are wired into the Xcode project (`project.pbxproj`):
PBXFileReference, PBXBuildFile, PtpCameraAgent group, and Sources build phase entries all added.

Fixes made during build verification:
- `handlePtpEvent(_:data:)` moved from `extension PtpCamera: ICCameraDeviceDelegate` into the
  main class body — Swift forbids overriding extension-defined methods in subclasses
- `info.formatValue(enumVal)` calls in `AppDelegate.swift` corrected to
  `camera.formatValue(enumVal, forProperty: info.propertyId)` — `PtpPropertyInfo` has no
  `formatValue` method; the camera instance does

`xcodebuild -scheme PtpCameraAgent -configuration Debug build` → **BUILD SUCCEEDED**

### Tooling
- XcodeBuildMCP installed at `~/.claude/mcp.json` (active from next session onward)

### Live view pipeline ✓ (completed)

**Bidirectional IPC** (extension ↔ agent) via Darwin notify state slots:
- Extension → agent: `kDarwinLiveViewStart` / `kDarwinLiveViewStop` with camera ID encoded
  in `kDarwinLiveViewCmdSlotPrefix` slots (slot 0 = length, slots 1–8 = UTF-8 bytes)
- Agent → extension: `kDarwinLiveViewFrame` with IOSurface ID + camera ID encoded in
  `kDarwinLiveViewFrameSlotPrefix` slots (slot 0 = `(surfaceID << 32) | length`, slots 1–8 = bytes)

**JPEG pipeline per vendor**:
- Nikon: `STARTLIVEVIEW` → poll `DEVICEREADY` → 30fps `GETLIVEVIEWIMG` → skip header bytes → JPEG
- Canon: `EVF_MODE=1` → `EVF_OUTPUTDEVICE=2` → 30fps `GETVIEWFINDERDATA` (param `0x00100000`) → JPEG
- Sony: immediately ready → 30fps `GETOBJECT(0xFFFFC002)` → JPEG

**Frame delivery** (agent → extension):
- `AppDelegate.publishLiveViewFrame(_:cameraId:)` decodes JPEG via CoreGraphics into a
  1920×1080 BGRA `IOSurface`; publishes surface ID via Darwin notify
- Extension `handleLiveViewFrame()` looks up surface with `IOSurfaceLookup()`,
  wraps in `CVPixelBuffer` via `CVPixelBufferCreateWithIOSurface`, sends as `CMSampleBuffer`

**White-stripe demo** (simulated camera only):
- Runs at 30fps only for the `isDemo` camera; real cameras never start the demo timer
- Speed setting (Slow/Medium/Fast) exposed in the menu bar under the simulated camera,
  same `  Property: Value →` submenu pattern as real camera properties
- Speed persisted in UserDefaults (`simulatedStripeSpeed`); published in camera state JSON;
  extension applies it live without reconnecting the device

**Menu bar icon**: status item now uses `StatusBarIcon` template image (22×22 camera logo)
instead of "PTP" text; adapts automatically to light/dark menu bar.

**Reinstall script fix** (`scripts/reinstall-extension.sh`): agent is an SMAppService with
`KeepAlive=true`; killing it before the build caused launchd to restart it from the old binary.
Fix: kill the agent *after* the build (step 4b) so launchd restarts from the new binary.

All three targets (`PtpWebcamApp`, `PtpCameraAgent`, `PtpWebcamCameraExtension`): **BUILD SUCCEEDED** ✓
Runtime validated: white-stripe visible in Photo Booth with simulated camera.

## Not Yet Done

### Future work (not started)
- **Runtime validation with real camera**: live view pipeline (IOSurface cross-sandbox lookup,
  per-vendor JPEG acquisition) not yet tested with actual hardware
- **Shared framework**: DarwinNotify.swift and PtpCameraAgentProtocol.swift are duplicated
  between PtpCameraAgent and PtpWebcamCameraExtension — move to a shared framework or symlink
- **Package scripts**: `ptpwebcam-package` needs rewrite for CMIOExtension (Phase 8+)

## File locations

| File | Path |
|------|------|
| Base class | `PtpCameraAgent/PtpCamera.swift` |
| Nikon subclass | `PtpCameraAgent/PtpCameraNikon.swift` |
| Canon subclass | `PtpCameraAgent/PtpCameraCanon.swift` |
| Sony subclass | `PtpCameraAgent/PtpCameraSony.swift` |
| Agent app delegate | `PtpCameraAgent/AppDelegate.swift` |
| Darwin notify | `PtpCameraAgent/DarwinNotify.swift` |
| Shared constants | `PtpCameraAgent/PtpCameraAgentProtocol.swift` |
| Old Obj-C reference | `PtpWebcamDalPlugin/PtpCamera*.{h,m}` |
| PTP constants ref | `PtpWebcamDalPlugin/PtpWebcamPtp.h` |
| Architecture doc | `AGENTS.md` |
