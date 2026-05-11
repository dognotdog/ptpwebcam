#!/bin/bash
# Rebuild and install PtpWebcamApp.  Opening the new app triggers the
# OSSystemExtensionRequest upgrade path — the same mechanism used in
# AppStore distribution.  The app also handles PtpCameraAgent via launchd.
#
# Usage: ./scripts/reinstall-extension.sh [--reset] [--restart] [version_number]
#   --reset    Wipe the extensions database (forces re-approval in System Settings)
#   --restart  Skip build; just kill the app and reopen it to force extension restart
#   version    Explicit version; default auto-increments from the installed one.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/PTP Webcam.xcodeproj"
EXT_BUNDLE_ID="org.ptpwebcam.CameraExtension"
EXT_BIN="org.ptpwebcam.CameraExtension"
INSTALL_PATH="/Applications/PtpWebcamApp.app"
TEAM_ID="ZYF8X9Z6M2"

RESET=false
RESTART_ONLY=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --reset)   RESET=true ;;
        --restart) RESTART_ONLY=true ;;
        *)         VERSION="$arg" ;;
    esac
done

# ── Shared helper: trigger CMIO enumeration + wait for process ────────

wait_for_ext_process() {
    local expected_ver="$1"
    # Start streaming extension logs BEFORE triggering launch, so we don't miss
    # the "extension started" line that fires immediately on startup.
    local log_file
    log_file=$(mktemp /tmp/ptpwebcam-ext-log.XXXXXX)
    /usr/bin/log stream \
        --predicate 'subsystem == "org.ptpwebcam.CameraExtension"' \
        --style compact > "$log_file" 2>&1 &
    local log_pid=$!
    sleep 0.5   # let log stream attach before we trigger launch

    # Also check if it already logged (quick restart may have fired before we attached).
    if /usr/bin/log show --last 5s \
            --predicate 'subsystem == "org.ptpwebcam.CameraExtension"' \
            --style compact 2>/dev/null | grep -q "PtpWebcam extension started build=$expected_ver"; then
        echo "    (already running — found in recent log history)"
        kill "$log_pid" 2>/dev/null; wait "$log_pid" 2>/dev/null
        /usr/bin/log show --last 5s \
            --predicate 'subsystem == "org.ptpwebcam.CameraExtension"' \
            --style compact 2>/dev/null | grep "PtpWebcam extension" | head -6
        rm -f "$log_file"
        return 0
    fi

    # Trigger CMIO device enumeration — this makes macOS launch the extension.
    echo "    Triggering CMIO device scan (starts extension process)..."
    ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>/dev/null | \
        grep -E "ptpwebcam|PTP|Webcam|NIKON|Canon|Sony" || true

    echo -n "    Waiting for 'extension started build=$expected_ver' in log"
    local found=false
    for i in $(seq 1 20); do
        if grep -q "PtpWebcam extension started build=$expected_ver" "$log_file" 2>/dev/null; then
            found=true
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""

    kill "$log_pid" 2>/dev/null
    wait "$log_pid" 2>/dev/null

    if $found; then
        grep "PtpWebcam extension\|IOKit:\|Added device" "$log_file" | head -8
        rm -f "$log_file"
        return 0
    else
        echo "    No startup log seen for build=$expected_ver.  Raw output:"
        grep "PtpWebcam" "$log_file" | head -10
        rm -f "$log_file"
        return 1
    fi
}

show_ext_logs() {
    echo ""
    echo "=== Recent extension logs (last 30s) ==="
    log show --last 30s \
        --predicate 'subsystem == "org.ptpwebcam.CameraExtension"' \
        --style compact 2>/dev/null | tail -30 || true
    echo ""
    echo "=== Sandbox/crash hints ==="
    log show --last 60s \
        --predicate 'process == "sandboxd" OR (eventMessage CONTAINS "org.ptpwebcam")' \
        --style compact 2>/dev/null | tail -20 || true
}

# ── --restart path: skip build, just restart app + extension ─────────

if $RESTART_ONLY; then
    echo "=== PTP Webcam Extension Restart (no build) ==="
    # Read version from the app bundle (not systemextensionsctl, which may lag after a reset).
    CURRENT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "$INSTALL_PATH/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension/Contents/Info.plist" \
        2>/dev/null || echo "?")
    echo "    App bundle version: $CURRENT_VER"

    echo "[1/2] Stopping PtpWebcamApp and extension..."
    killall PtpWebcamApp 2>/dev/null || true
    # Also kill the extension process if it's running — CMIO will restart it
    pkill -f "$EXT_BIN" 2>/dev/null || true
    sleep 1

    echo "[2/2] Reopening app (triggers extension re-launch)..."
    open "$INSTALL_PATH"
    sleep 1

    if wait_for_ext_process "$CURRENT_VER"; then
        EXT_PID=$(pgrep -f "$EXT_BIN" 2>/dev/null | head -1 || echo "?")
        echo "✅ Extension v$CURRENT_VER started and logged (PID ${EXT_PID:-?})."
    else
        echo "❌ Extension did not log startup — likely crashed or not launched."
        show_ext_logs
    fi
    exit 0
fi

# ── Normal path: auto-increment version ───────────────────────────────

if [[ -z "$VERSION" ]]; then
    CURRENT=$(systemextensionsctl list 2>&1 \
        | grep "$EXT_BUNDLE_ID" \
        | grep -v 'terminated' \
        | grep -o '1\.0/[0-9]*' \
        | head -1 \
        | cut -d/ -f2)
    CURRENT=${CURRENT:-0}
    VERSION=$((CURRENT + 1))
fi

echo "=== PTP Webcam Extension Reinstall ==="
echo "    Project:  $PROJECT_DIR"
echo "    Version:  $VERSION"

# ── 1. Optional reset ─────────────────────────────────────────────────
TERMINATED_COUNT=$(systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -c "terminated waiting to uninstall" || true)

if $RESET; then
    echo "[1/5] Resetting system extensions database (will require re-approval)..."
    sudo -n systemextensionsctl reset 2>&1 || { echo "    (sudo needed — run: sudo systemextensionsctl reset)"; }
elif [[ "$TERMINATED_COUNT" -gt 4 ]]; then
    echo "[1/5] Auto-reset: $TERMINATED_COUNT terminated entries found — resetting database..."
    echo "      (You will need to re-approve in System Settings after this.)"
    sudo -n systemextensionsctl reset 2>&1 || { echo "    (sudo needed — run: sudo systemextensionsctl reset)"; }
else
    echo "[1/5] $TERMINATED_COUNT terminated entries — no reset needed."
fi

# ── 2. Stop the running app (so the build can overwrite it) ───────────
echo "[2/5] Stopping PtpWebcamApp..."
killall PtpWebcamApp 2>/dev/null || true
pkill -f "$EXT_BIN" 2>/dev/null || true
sleep 0.3

# ── 3. Build ──────────────────────────────────────────────────────────
echo "[3/5] Building (CURRENT_PROJECT_VERSION=$VERSION)..."
BUILD_OUTPUT=$(xcodebuild \
    -project "$PROJECT" \
    -target PtpWebcamApp \
    -configuration Debug \
    build \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    2>&1)

if echo "$BUILD_OUTPUT" | grep -q '^\*\* BUILD SUCCEEDED'; then
    echo "    Build succeeded."
else
    echo "$BUILD_OUTPUT" | grep -E 'error:' || true
    echo "ERROR: Build failed."
    exit 1
fi

# Verify the built extension has the expected version
BUILT_EXT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$INSTALL_PATH/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension/Contents/Info.plist" \
    2>/dev/null || echo "?")
echo "    Extension bundle version in app: $BUILT_EXT_VER"

# Sanity-check: ensure the built binary has our expected startup string
INIT_VER=$(strings "$INSTALL_PATH/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension/Contents/MacOS/$EXT_BUNDLE_ID" 2>/dev/null | grep "PtpWebcam extension started" | head -1 || echo "(not found)")
echo "    Binary reports: $INIT_VER"

# ── 4. Open app — triggers OSSystemExtensionRequest upgrade ──────────
echo "[4/5] Opening app (triggers extension upgrade + agent restart)..."
open "$INSTALL_PATH"

# Wait for the extension to appear activated at the expected version
echo -n "    Waiting for systemextensionsctl to show v$VERSION activated"
EXT_ACTIVATED=false
for i in $(seq 1 25); do
    ACTIVE_VER=$(systemextensionsctl list 2>&1 \
        | grep "$EXT_BUNDLE_ID" \
        | grep "activated enabled" \
        | grep -o '1\.0/[0-9]*' \
        | cut -d/ -f2 || true)
    if [[ "$ACTIVE_VER" == "$VERSION" ]]; then
        EXT_ACTIVATED=true
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

# ── 5. Trigger CMIO + verify the extension PROCESS is running ─────────
echo "[5/5] Verifying extension started (watching logs)..."
EXT_RUNNING=false

if $EXT_ACTIVATED; then
    if wait_for_ext_process "$VERSION"; then
        EXT_RUNNING=true
    fi
fi

# ── Status ────────────────────────────────────────────────────────────
echo ""
echo "Extension status:"
systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -v terminated || true
echo ""

if $EXT_RUNNING; then
    EXT_PID=$(pgrep -f "$EXT_BIN" 2>/dev/null | head -1 || echo "?")
    echo "✅ Extension v$VERSION started and logged (PID ${EXT_PID:-?})."
elif ! $EXT_ACTIVATED; then
    STATUS=$(systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -v terminated || true)
    STILL_TERMINATED=$(systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -c "terminated waiting to uninstall" || true)
    if echo "$STATUS" | grep -q "waiting for user"; then
        echo ">>> Extension needs approval:"
        echo ">>>   System Settings → Privacy & Security → scroll to Security → Allow"
        echo ">>>   (the app shows an alert guiding you there)"
    elif [[ "$STILL_TERMINATED" -gt 0 ]]; then
        echo "⚠️  $STILL_TERMINATED terminated entries remain. Run with --reset:"
        echo "   bash scripts/reinstall-extension.sh --reset"
    else
        echo "⚠️  systemextensionsctl did not show v$VERSION activated after 25s."
    fi
else
    echo "❌ Extension v$VERSION is activated but process did not start."
    echo "   This usually means the extension crashed at init (sandbox violation, bad entitlements, etc.)."
    show_ext_logs
fi

echo ""
echo "Verify:"
echo "  ffmpeg -hide_banner -f avfoundation -list_devices true -i \"\""
echo "  log show --last 30s --predicate 'subsystem == \"org.ptpwebcam.CameraExtension\"' --style compact"
