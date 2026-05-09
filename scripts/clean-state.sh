#!/bin/bash
# Clean all PTP Webcam runtime state so the next reinstall starts fresh.
# Requires sudo for: system extension reset, xattr removal, killing root-owned processes.
#
# Usage: sudo bash scripts/clean-state.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root: sudo bash scripts/clean-state.sh"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_LABEL="org.ptpwebcam.PtpCameraAgent"
APP_BUNDLE="/Applications/PtpWebcamApp.app"
AGENT_PLIST_SOURCE="$PROJECT_DIR/PtpWebcamApp/$AGENT_LABEL.plist"

# Resolve the real (non-sudo) user home directory
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo ~"$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

echo "=== PTP Webcam Clean State ==="
echo "    User:    $REAL_USER (uid $REAL_UID)"
echo "    Project: $PROJECT_DIR"
echo ""

# ── 1. Stop running processes ─────────────────────────────────────────
echo "[1] Stopping processes..."
killall PtpWebcamApp  2>/dev/null && echo "    Stopped PtpWebcamApp"  || echo "    PtpWebcamApp not running"
killall PtpCameraAgent 2>/dev/null && echo "    Stopped PtpCameraAgent" || echo "    PtpCameraAgent not running"
sleep 0.5

# ── 2. Bootout launchd services ───────────────────────────────────────
echo "[2] Booting out launchd services..."
launchctl bootout "gui/$REAL_UID/$AGENT_LABEL" 2>/dev/null \
    && echo "    Booted out $AGENT_LABEL" \
    || echo "    $AGENT_LABEL not loaded (OK)"
launchctl bootout "gui/$REAL_UID/org.ptpwebcam.CameraAgent" 2>/dev/null \
    && echo "    Booted out CameraAgent" \
    || echo "    CameraAgent not loaded (OK)"

# ── 3. Remove old LaunchAgent plists from ~/Library/LaunchAgents ──────
echo "[3] Removing ~/Library/LaunchAgents plists..."
for f in \
    "$REAL_HOME/Library/LaunchAgents/org.ptpwebcam.PtpCameraAgent.plist" \
    "$REAL_HOME/Library/LaunchAgents/org.ptpwebcam.CameraAgent.plist" \
    "$REAL_HOME/Library/LaunchAgents/org.ptpwebcam.PtpWebcamAssistant.plist" \
    "$REAL_HOME/Library/LaunchAgents/org.ptpwebcam.PtpWebcamAgent.plist"
do
    if [ -f "$f" ]; then
        rm "$f" && echo "    Removed $f"
    fi
done

# ── 4. Remove com.apple.provenance from source plist ─────────────────
# This attribute (applied by the Claude agent process) prevents SMAppService
# from finding the plist.  Sudo can strip it; the result persists in the repo.
echo "[4] Stripping com.apple.provenance from source plist..."
if [ -f "$AGENT_PLIST_SOURCE" ]; then
    xattr -d com.apple.provenance "$AGENT_PLIST_SOURCE" 2>/dev/null \
        && echo "    Stripped provenance from source plist" \
        || echo "    No provenance attribute on source plist (already clean)"
    REMAINING=$(xattr -l "$AGENT_PLIST_SOURCE" 2>/dev/null || true)
    echo "    Remaining attrs: ${REMAINING:-none}"
fi

# Also strip from the worktree copy if present
WORKTREE_PLIST="$PROJECT_DIR/.claude/worktrees/xenodochial-brown-ad6ab0/PtpWebcamApp/$AGENT_LABEL.plist"
if [ -f "$WORKTREE_PLIST" ]; then
    xattr -d com.apple.provenance "$WORKTREE_PLIST" 2>/dev/null || true
    echo "    Stripped provenance from worktree plist"
fi

# ── 5. Remove com.apple.provenance from installed app plists ─────────
echo "[5] Stripping provenance from installed app bundle plists..."
if [ -d "$APP_BUNDLE/Contents/Library/LaunchAgents" ]; then
    for f in "$APP_BUNDLE/Contents/Library/LaunchAgents/"*.plist; do
        [ -f "$f" ] || continue
        BEFORE=$(xattr -l "$f" 2>/dev/null | grep provenance || true)
        if [ -n "$BEFORE" ]; then
            xattr -d com.apple.provenance "$f" 2>/dev/null || true
            echo "    Stripped: $f"
        fi
    done
fi

# ── 6. Reset BackgroundTaskManagement database ───────────────────────
# Clears stale SMAppService registrations so the next install starts fresh.
echo "[6] Resetting BackgroundTaskManagement database..."
sudo -u "$REAL_USER" sfltool resetbtm 2>/dev/null \
    && echo "    BTM database reset" \
    || echo "    BTM reset failed (sfltool not available?)"

# ── 7. Reset system extension database ───────────────────────────────
echo "[7] Resetting system extension database..."
systemextensionsctl reset 2>/dev/null \
    && echo "    Extension database reset (re-approval required after next install)" \
    || echo "    Reset failed (may need SIP disabled or reboot pending)"

# ── 8. Clear agent log ────────────────────────────────────────────────
echo "[8] Clearing agent log..."
truncate -s 0 /tmp/PtpCameraAgent.log 2>/dev/null && echo "    Cleared /tmp/PtpCameraAgent.log" || true

echo ""
echo "✅ Done. Now run:"
echo "   bash scripts/reinstall-extension.sh"
echo ""
echo "   The extension will need re-approval in System Settings → Privacy & Security."
