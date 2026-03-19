#!/bin/bash
set -e

# =============================================================================
# Deploy GemRB to TrimUI Brick via adb
#
# Deploys engine.zip + device configs, with backup for rollback.
# Run ./build.sh first to produce engine.zip.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_DIR="/mnt/mmc/ports/gemrb"
ENGINE_ZIP="$SCRIPT_DIR/engine.zip"

# --- Preflight checks ---

if [ ! -f "$ENGINE_ZIP" ]; then
    echo "ERROR: engine.zip not found. Run ./build.sh first."
    exit 1
fi

if ! adb devices 2>/dev/null | grep -q "device$"; then
    echo "ERROR: No adb device connected."
    exit 1
fi

echo "=== Deploying GemRB to TrimUI Brick ==="
echo ""

# --- Backup current state ---

BACKUP="engine.backup.$(date +%Y%m%d_%H%M%S)"
echo ">>> Backing up current engine/ → $BACKUP"
adb shell "cp -r $DEVICE_DIR/engine $DEVICE_DIR/$BACKUP"
adb shell "cp $DEVICE_DIR/gemrb $DEVICE_DIR/$BACKUP/gemrb.root"
adb shell "cp $DEVICE_DIR/lib/libgemrb_core.so $DEVICE_DIR/$BACKUP/libgemrb_core.so.lib"
echo "    Backup at: $DEVICE_DIR/$BACKUP"

# --- Deploy engine ---

echo ""
echo ">>> Pushing engine.zip..."
adb push "$ENGINE_ZIP" /tmp/engine.zip

echo ">>> Extracting engine..."
adb shell "rm -rf $DEVICE_DIR/engine && mkdir -p $DEVICE_DIR/engine && cd $DEVICE_DIR/engine && unzip -o /tmp/engine.zip && rm /tmp/engine.zip"

echo ">>> Updating gemrb binary..."
adb shell "cp $DEVICE_DIR/engine/gemrb $DEVICE_DIR/gemrb"

echo ">>> Updating libgemrb_core.so..."
adb shell "cp $DEVICE_DIR/engine/libgemrb_core.so $DEVICE_DIR/lib/libgemrb_core.so 2>/dev/null || cp \$(ls $DEVICE_DIR/engine/libgemrb_core.so.* 2>/dev/null | head -1) $DEVICE_DIR/lib/libgemrb_core.so"

# --- Sync device configs ---

echo ""
echo ">>> Syncing device configs..."

adb push "$SCRIPT_DIR/device/gemrb.gptk" "$DEVICE_DIR/gemrb.gptk"

adb shell "mkdir -p $DEVICE_DIR/fonts"
adb push "$SCRIPT_DIR/device/fonts/Literata.ttf" "$DEVICE_DIR/fonts/Literata.ttf"

adb shell "mkdir -p $DEVICE_DIR/games/pst/override"
adb push "$SCRIPT_DIR/device/games/pst/override/fonts.2da" "$DEVICE_DIR/games/pst/override/fonts.2da"

echo ">>> Syncing custom Python scripts..."
for pyf in "$SCRIPT_DIR/custom_scripts/pst/"*.py; do
    adb push "$pyf" "$DEVICE_DIR/games/pst/override/$(basename "$pyf")"
done

echo ">>> Patching gemrb.ini (ButtonFont = NORMAL)..."
adb push "$SCRIPT_DIR/device/engine/unhardcoded/pst/gemrb.ini" "$DEVICE_DIR/engine/unhardcoded/pst/gemrb.ini"

echo ">>> Disabling GamepadSupport (gptokeyb handles D-pad as mouse)..."
PST_CFG="$DEVICE_DIR/games/pst/GemRB.cfg"
adb shell "grep -q '^GamepadSupport' $PST_CFG 2>/dev/null && sed -i 's/^GamepadSupport=.*/GamepadSupport=0/' $PST_CFG || echo 'GamepadSupport=0' >> $PST_CFG"

# --- Done ---

echo ""
echo "=== SUCCESS ==="
echo ""
echo "Backup: $DEVICE_DIR/$BACKUP"
echo "To revert:"
echo "  adb shell \"rm -rf $DEVICE_DIR/engine && cp -r $DEVICE_DIR/$BACKUP $DEVICE_DIR/engine\""
echo "  adb shell \"cp $DEVICE_DIR/$BACKUP/gemrb.root $DEVICE_DIR/gemrb\""
echo "  adb shell \"cp $DEVICE_DIR/$BACKUP/libgemrb_core.so.lib $DEVICE_DIR/lib/libgemrb_core.so\""
