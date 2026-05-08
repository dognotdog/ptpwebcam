#!/bin/bash
# Rebuild and upgrade the CMIOExtension in place.
#
# If the extension is already approved, the version bump triggers an automatic
# upgrade with no manual System Settings toggle.  Manual approval is only
# needed the very first time (or after "systemextensionsctl reset").
#
# Usage: ./scripts/reinstall-extension.sh [--reset] [version_number]
#   --reset   Wipe the extensions database (forces re-approval in System Settings)
#   version   Explicit version; default auto-increments from the installed one.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/PTP Webcam.xcodeproj"
EXT_BUNDLE_ID="org.ptpwebcam.CameraExtension"
INSTALL_PATH="/Applications/PtpWebcamApp.app"
TEAM_ID="ZYF8X9Z6M2"

RESET=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --reset) RESET=true ;;
        *)       VERSION="$arg" ;;
    esac
done

# Auto-increment version from whatever is currently installed
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

echo "=== PTP Webcam Extension Reinstall (version $VERSION) ==="

# ── 1. Stop everything ────────────────────────────────────────────────
echo "[1/6] Stopping running processes..."
# Kill the host app (needed so the extension can be replaced).
# Do NOT kill PtpCameraAgent here — it has KeepAlive=true in its SMAppService
# plist, so launchd would immediately restart it from the OLD binary.
# We kill it after the build instead (step 4b), so launchd restarts it from
# the newly-installed binary.
killall PtpWebcamApp 2>/dev/null || true

# ── 2. Optional reset ─────────────────────────────────────────────────
if $RESET; then
    echo "[2/6] Resetting system extensions database (will require re-approval)..."
    systemextensionsctl reset 2>&1 || true
else
    echo "[2/6] Keeping existing approval (no reset)."
fi

# ── 3. Wait for the old extension process to exit ─────────────────────
echo -n "[3/6] Waiting for old extension process to exit"
for i in $(seq 1 20); do
    if ! pgrep -f "$EXT_BUNDLE_ID" >/dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

if pgrep -f "$EXT_BUNDLE_ID" >/dev/null 2>&1; then
    echo "    WARNING: Old extension process still running (PID $(pgrep -f "$EXT_BUNDLE_ID"))."
    echo "    The upgrade may hit the launchd race condition."
    echo "    Consider: sudo kill $(pgrep -f "$EXT_BUNDLE_ID")  or reboot."
fi

# ── 4. Build ──────────────────────────────────────────────────────────
echo "[4/6] Building (CURRENT_PROJECT_VERSION=$VERSION)..."
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

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$INSTALL_PATH/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension/Contents/Info.plist" 2>/dev/null || echo "?")
echo "    Extension bundle version: $BUILT_VERSION"

# ── 4b. Restart agent from new binary ────────────────────────────────
echo "[4b] Restarting PtpCameraAgent (launchd will relaunch from new binary)..."
killall PtpCameraAgent 2>/dev/null || true
# Brief pause so launchd has time to restart it before we open the host app.
sleep 1

# ── 5. Launch app → triggers activation/upgrade ──────────────────────
echo "[5/6] Launching app..."
open "$INSTALL_PATH"

# Wait for the extension to appear
echo -n "    Waiting for extension process"
EXT_RUNNING=false
for i in $(seq 1 15); do
    if pgrep -f "$EXT_BUNDLE_ID" >/dev/null 2>&1; then
        EXT_RUNNING=true
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

# ── 6. Status ─────────────────────────────────────────────────────────
echo "[6/6] Extension status:"
systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" || true
echo ""

if $EXT_RUNNING; then
    EXT_PID=$(pgrep -f "$EXT_BUNDLE_ID" | head -1)
    echo "Extension process running (PID $EXT_PID)."
else
    STATUS=$(systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -v terminated || true)
    if echo "$STATUS" | grep -q "waiting for user"; then
        echo ">>> Extension needs approval in System Settings:"
        echo ">>>   General > Login Items & Extensions > Camera Extensions"
    else
        echo "Extension process not running. Check logs:"
        echo "  /usr/bin/log show --last 30s --predicate 'process CONTAINS \"CameraExtension\"' --style compact"
    fi
fi

echo ""
echo "Verify:"
echo "  cat /tmp/PtpCameraAgent.log"
echo "  /usr/bin/log show --last 30s --predicate 'subsystem == \"org.ptpwebcam.CameraExtension\"' --style compact"
