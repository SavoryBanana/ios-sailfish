#!/bin/bash
# build-and-flash-root.sh: Build the iOS 16 root filesystem, apply tweaks/wallpapers,
# convert to Android sparse image, and flash to Google Pixel 1 (sailfish).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

echo "========================================================"
echo "  iOS 16 on Google Pixel 1 (sailfish) - Root Build"
echo "========================================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo to mount APFS/HFS+ images."
    echo "Usage: sudo ./build-and-flash-root.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

echo ""
echo "=== Step 1: Building Base HFS+ Image (16G) ==="
if [ ! -f "ios16-root.img" ]; then
    bash "$HERE/tools/mkiosroot.sh" \
        "$HERE/staging/OS.dmg" \
        "$HERE/staging/SystemOS.dmg" \
        "$HERE/staging/AppOS.dmg" \
        "$HERE/ios16-root.img" 16G
else
    echo "ios16-root.img already exists, skipping base assembly."
fi

echo ""
echo "=== Step 2: Applying Post-Build Tweaks & Wallpaper Fixes ==="
MNT=$(mktemp -d /tmp/iosroot-mnt.XXXXXX)
cleanup() {
    if mountpoint -q "$MNT"; then
        umount "$MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

fsck.hfsplus -fy "$HERE/ios16-root.img" || true
mount -t hfsplus -o loop,force "$HERE/ios16-root.img" "$MNT"

# Move staged system apps into /Applications (iOS first-boot codesigning bypass)
if [ -d "$MNT/private/var/staged_system_apps" ] && [ "$(ls -A "$MNT/private/var/staged_system_apps" 2>/dev/null)" ]; then
    echo "Moving staged system apps into /Applications..."
    mv "$MNT/private/var/staged_system_apps/"* "$MNT/Applications/"
fi

# Apply system tweaks (launchd panic disable, preferences, mobileactivationd)
echo "Running sweet-root-tweaks.py..."
python3 "$HERE/tools/sweet-root-tweaks.py" "$MNT"

# Install sweetgl.dylib (Mesa GPU acceleration) if available
if [ -f "$HERE/staging/sweetgl/sweetgl.dylib" ]; then
    echo "Installing sweetgl.dylib for GPU acceleration..."
    mkdir -p "$MNT/usr/lib"
    cp "$HERE/staging/sweetgl/sweetgl.dylib" "$MNT/usr/lib/sweetgl.dylib"
    chmod 755 "$MNT/usr/lib/sweetgl.dylib"
    chown 0:0 "$MNT/usr/lib/sweetgl.dylib"
fi

# Convert wallpapers (HEIC -> PNG) using heif-convert
echo "Converting stock wallpapers (HEIC -> PNG)..."
n=0
while IFS= read -r -d '' heic; do
    png="${heic%.*}.png"
    if [ ! -f "$png" ]; then
        heif-convert "$heic" "$png" >/dev/null 2>&1 || true
        n=$((n + 1))
    fi
done < <(find "$MNT/Library/Wallpaper/Collections" -name '*.HEIC' -print0 2>/dev/null)
echo "$n HEIC wallpapers converted."

while IFS= read -r -d '' caml; do
    if grep -q '\.HEIC"' "$caml"; then
        sed -i 's/\.HEIC"/.png"/g' "$caml"
        echo "Updated wallpaper caml: ${caml#"$MNT"/}"
    fi
done < <(find "$MNT/Library/Wallpaper/Collections" -name main.caml -print0 2>/dev/null)

# Clean up unwanted metadata
rm -rf "$MNT/.fseventsd" "$MNT/.Spotlight-V100" "$MNT/.Trashes"

echo "Unmounting image..."
umount "$MNT"
fsck.hfsplus -fy "$HERE/ios16-root.img" || true
chown "$REAL_USER":"$REAL_USER" "$HERE/ios16-root.img"

echo ""
echo "=== Step 3: Converting to Android Sparse Image ==="
su - "$REAL_USER" -c "python3 '$HERE/tools/img2simg.py' '$HERE/ios16-root.img' '$HERE/ios16-root.simg'"

echo ""
echo "=== Step 4: Flashing to Pixel 1 (userdata) ==="
su - "$REAL_USER" -c "fastboot flash userdata '$HERE/ios16-root.simg'"

echo ""
echo "=== Step 5: Booting iOS 16! ==="
su - "$REAL_USER" -c "fastboot boot '$HERE/shim/out/pixel-boot.img'"

echo ""
echo "========================================================"
echo "  iOS 16 is now booting on your Google Pixel 1!"
echo "  Note: First boot takes 2-4 minutes for data migration."
echo "========================================================"

