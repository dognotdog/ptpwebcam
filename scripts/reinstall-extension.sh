#!/bin/bash
# Rebuild and install PtpWebcamApp.  Opening the new app triggers the
# OSSystemExtensionRequest upgrade path — the same mechanism used in
# AppStore distribution.  The app also handles PtpCameraAgent via launchd.
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

echo "=== PTP Webcam Extension Reinstall ==="
echo "    Project:  $PROJECT_DIR"
echo "    Version:  $VERSION"

# ── 1. Optional reset ─────────────────────────────────────────────────
TERMINATED_COUNT=$(systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" | grep -c "terminated waiting to uninstall" || true)

if $RESET; then
    echo "[1/4] Resetting system extensions database (will require re-approval)..."
    sudo systemextensionsctl reset 2>&1 || true
elif [[ "$TERMINATED_COUNT" -gt 4 ]]; then
    echo "[1/4] Auto-reset: $TERMINATED_COUNT terminated entries found — resetting database..."
    echo "      (You will need to re-approve in System Settings after this.)"
    sudo systemextensionsctl reset 2>&1 || true
else
    echo "[1/4] $TERMINATED_COUNT terminated entries — no reset needed."
fi

# ── 2. Stop the running app (so the build can overwrite it) ───────────
echo "[2/4] Stopping PtpWebcamApp..."
killall PtpWebcamApp 2>/dev/null || true
sleep 0.3

# ── 3. Build ──────────────────────────────────────────────────────────
echo "[3/4] Building (CURRENT_PROJECT_VERSION=$VERSION)..."
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

# Sanity-check: ensure the built binary has our expected init string
INIT_VER=$(strings "$INSTALL_PATH/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension/Contents/MacOS/$EXT_BUNDLE_ID" 2>/dev/null | grep "Extension init" | head -1)
echo "    Binary reports: $INIT_VER"

# ── 4. Open app — triggers OSSystemExtensionRequest upgrade ──────────
echo "[4/4] Opening app (triggers extension upgrade + agent restart)..."
open "$INSTALL_PATH"

# Wait for the extension to appear activated at the expected version
echo -n "    Waiting for extension v$VERSION"
EXT_RUNNING=false
for i in $(seq 1 25); do
    ACTIVE_VER=$(systemextensionsctl list 2>&1 \
        | grep "$EXT_BUNDLE_ID" \
        | grep "activated enabled" \
        | grep -o '1\.0/[0-9]*' \
        | cut -d/ -f2 || true)
    if [[ "$ACTIVE_VER" == "$VERSION" ]]; then
        EXT_RUNNING=true
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

# ── Status ────────────────────────────────────────────────────────────
echo ""
echo "Extension status:"
systemextensionsctl list 2>&1 | grep "$EXT_BUNDLE_ID" || true
echo ""

if $EXT_RUNNING; then
    EXT_PID=$(pgrep -f "$EXT_BUNDLE_ID" 2>/dev/null | head -1 || echo "?")
    echo "✅ Extension v$VERSION active (PID ${EXT_PID})."
else
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
        echo "⚠️  Extension not yet running (starts on demand when a camera app opens)."
    fi
fi

echo ""
echo "Verify:"
echo "  cat /tmp/PtpCameraAgent.log"
echo "  /usr/bin/log show --last 30s --predicate 'subsystem == \"org.ptpwebcam.CameraExtension\"' --style compact"
