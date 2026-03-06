#!/bin/bash
set -e

# =============================================================================
# GemRB Master (3a52c5fd48) Build — TrimUI Brick / MuOS
#
# Builds upstream master (3a52c5fd48) with 7 compatibility patches:
#   - CORE_fixes: OnMouseDrag crash fix, Esc-in-dialog block, weapon anim on equip/remove
#   - GLES2_fixes: hardcode OPENGLES2_FOUND for Docker build
#   - GLES2_shader_fix: GLES2 attribute bindings, projection matrix, vertex shader
#   - dialogue_customization: SetMargins Python binding, name format, compact options
#   - video_fix: RGB555 format fallthrough + source pitch fix for GLES2 video
#   - dialogue_footer: TextArea scroll info API for "more below" arrow indicator
#
# USE_SDL_CONTROLLER_API is OFF — TrimUI Brick has no analog sticks,
# so we use gptokeyb for D-pad mouse control and button remapping.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
WORK_DIR="$SCRIPT_DIR/.build"
UPSTREAM_REPO="${UPSTREAM_GEMRB:-$SCRIPT_DIR/upstream-gemrb}"
GEMRB_COMMIT="3a52c5fd48e902313fc028bea139fb3e68837aef"

echo "=== GemRB Master ($GEMRB_COMMIT) Builder ==="
echo ""

# Verify patches exist
for patch in CORE_fixes.patch GLES2_fixes.diff GLES2_shader_fix.patch dialogue_customization.patch video_fix.patch dialogue_footer.patch guireccommon_fix.patch; do
    if [ ! -f "$PATCH_DIR/$patch" ]; then
        echo "ERROR: Missing patch: $PATCH_DIR/$patch"
        exit 1
    fi
done

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/gemrb"

# Export master source from upstream repo (no .git, clean export)
echo ">>> Exporting upstream GemRB master ($GEMRB_COMMIT)..."
if [ ! -d "$UPSTREAM_REPO/.git" ]; then
    echo "ERROR: upstream-gemrb repo not found at $UPSTREAM_REPO"
    echo "  Run: git clone https://github.com/gemrb/gemrb.git $UPSTREAM_REPO"
    exit 1
fi
git -C "$UPSTREAM_REPO" archive "$GEMRB_COMMIT" | tar -x -C "$WORK_DIR/gemrb"

# Apply compatibility patches
cd "$WORK_DIR/gemrb"
git init -q
git add -A
git commit -q -m "master base $GEMRB_COMMIT"

echo ">>> Applying CORE_fixes (crash fix + Esc-in-dialog block + weapon anim)..."
git apply "$PATCH_DIR/CORE_fixes.patch"
echo "    Applied CORE_fixes.patch"

echo ">>> Applying GLES2_fixes (FindOpenGLES2.cmake)..."
git apply "$PATCH_DIR/GLES2_fixes.diff"
echo "    Applied GLES2_fixes.diff"

echo ">>> Applying GLES2_shader_fix (attribute bindings + projection matrix)..."
git apply "$PATCH_DIR/GLES2_shader_fix.patch"
echo "    Applied GLES2_shader_fix.patch"

echo ">>> Applying dialogue_customization (SetMargins binding + name format + compact options)..."
git apply "$PATCH_DIR/dialogue_customization.patch"
echo "    Applied dialogue_customization.patch"

echo ">>> Applying video_fix (RGB555 GLES2 format fallthrough + source pitch fix)..."
git apply "$PATCH_DIR/video_fix.patch"
echo "    Applied video_fix.patch"

echo ">>> Applying dialogue_footer (TextArea scroll info for footer arrow)..."
git apply "$PATCH_DIR/dialogue_footer.patch"
echo "    Applied dialogue_footer.patch"

echo ">>> Applying guireccommon_fix (lazy PaperDoll import — fixes PST stats panel)..."
git apply "$PATCH_DIR/guireccommon_fix.patch"
echo "    Applied guireccommon_fix.patch"

cd "$SCRIPT_DIR"

# Create the build script that runs inside Docker
cat > "$WORK_DIR/docker_build.sh" << 'DOCKEREOF'
#!/bin/bash
set -e

echo ">>> Installing build dependencies..."
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq python3.9-dev zip > /dev/null 2>&1

cd /workspace/gemrb

mkdir -p build && cd build

echo ">>> Configuring with CMake..."
cmake .. \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DLAYOUT=home \
  -DUSE_ICONV=OFF \
  -DDISABLE_VIDEOCORE=ON \
  -DUSE_LIBVLC=OFF \
  -DSDL_BACKEND=SDL2 \
  -DUSE_SDL_CONTROLLER_API="OFF" \
  -DSDL_RESOLUTION_INDEPENDANCE="ON" \
  -DCMAKE_INSTALL_PREFIX="/workspace/gemrb/build/engine" \
  -DOPENGL_BACKEND="GLES" \
  -DPYTHON_EXECUTABLE="/usr/bin/python3.9" \
  -DPYTHON_LIBRARY="/usr/lib/aarch64-linux-gnu/libpython3.9.so" \
  -DPYTHON_INCLUDE_DIR="/usr/include/python3.9" \
  -DLIB_DIR="engine" \
  -DPLUGIN_DIR="engine/plugins/" \
  -DDATA_DIR="engine" \
  -DBIN_DIR="engine" \
  -DSYSCONF_DIR="engine" \
  -DMAN_DIR="engine/man/man6" \
  -DCMAKE_INSTALL_RPATH="engine"

echo ">>> Building..."
make -j$(nproc)

echo ">>> Installing..."
make install

echo ">>> Overlaying custom Python scripts..."
cp /workspace/custom_scripts/pst/*.py /workspace/gemrb/build/engine/engine/GUIScripts/pst/
echo "    Copied: $(ls /workspace/custom_scripts/pst/*.py | xargs -n1 basename | tr '\n' ' ')"

echo ">>> Patching PST gemrb.ini (ButtonFont = NORMAL)..."
sed -i 's/^ButtonFont = FONTDLG/ButtonFont = NORMAL/' /workspace/gemrb/build/engine/engine/unhardcoded/pst/gemrb.ini
echo "    ButtonFont set to NORMAL (bitmap font for UI elements)"

echo ">>> Packaging engine.zip..."
cd /workspace/gemrb/build/engine/engine
zip -9r /workspace/engine.zip .

echo ""
echo "=== Build complete! ==="
echo "Output: /workspace/engine.zip"
ls -lh /workspace/engine.zip
DOCKEREOF
chmod +x "$WORK_DIR/docker_build.sh"

# Pull the PortMaster builder image and run the build
echo ""
echo ">>> Pulling PortMaster aarch64 build image..."
docker pull --platform=linux/arm64 ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest

echo ""
echo ">>> Starting build inside Docker..."
docker run --rm \
  --platform=linux/arm64 \
  -v "$WORK_DIR:/workspace" \
  -v "$SCRIPT_DIR/custom_scripts:/workspace/custom_scripts:ro" \
  ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest \
  /bin/bash /workspace/docker_build.sh

# Copy result
if [ -f "$WORK_DIR/engine.zip" ]; then
    cp "$WORK_DIR/engine.zip" "$SCRIPT_DIR/engine.zip"
    echo ""
    echo "=== SUCCESS ==="
    echo "Built engine.zip is at: $SCRIPT_DIR/engine.zip"
    echo ""
    echo "To deploy to your TrimUI Brick:"
    echo "  1. Backup current engine: adb shell \"cp -r /mnt/mmc/ports/gemrb/engine /mnt/mmc/ports/gemrb/engine.backup\""
    echo "  2. adb push engine.zip /tmp/"
    echo "  3. adb shell \"cd /mnt/mmc/ports/gemrb && rm -rf engine && mkdir engine && cd engine && unzip /tmp/engine.zip\""
    echo "  4. Ensure gptokeyb is enabled in GemRB.sh launch script"
    echo "  5. Uses gptokeyb + gemrb.gptk for D-pad mouse and button mapping"
    echo ""
    ls -lh "$SCRIPT_DIR/engine.zip"
else
    echo ""
    echo "=== BUILD FAILED ==="
    echo "engine.zip was not produced. Check the output above for errors."
    exit 1
fi
