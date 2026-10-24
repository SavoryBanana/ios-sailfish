#!/usr/bin/env bash
# update-root-image.sh: Inject sweetgl.dylib into local ios16-root.img and regenerate ios16-root.simg.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] This script requires root permissions."
    echo "    Usage: sudo ./update-root-image.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${HERE}/ios16-root.img"
DYLIB="${HERE}/staging/sweetgl/sweetgl.dylib"

if [ ! -f "${IMG}" ]; then
    echo "[-] Error: ${IMG} not found."
    exit 1
fi
if [ ! -f "${DYLIB}" ]; then
    echo "[-] Error: ${DYLIB} not found."
    exit 1
fi

MNT=$(mktemp -d /tmp/iosroot-mnt.XXXXXX)
cleanup() {
    if mountpoint -q "$MNT"; then
        umount "$MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "[*] Mounting ios16-root.img..."
fsck.hfsplus -fy "$IMG" || true
mount -t hfsplus -o loop,force "$IMG" "$MNT"

echo "[*] Copying sweetgl.dylib..."
mkdir -p "$MNT/usr/lib"
cp "$DYLIB" "$MNT/usr/lib/sweetgl.dylib"
chmod 755 "$MNT/usr/lib/sweetgl.dylib"
chown 0:0 "$MNT/usr/lib/sweetgl.dylib"

echo "[*] Unmounting..."
umount "$MNT"
fsck.hfsplus -fy "$IMG" || true
chown "$REAL_USER":"$REAL_USER" "$IMG"

echo "[*] Regenerating ios16-root.simg..."
su - "$REAL_USER" -c "python3 '${HERE}/tools/img2simg.py' '${IMG}' '${HERE}/ios16-root.simg'"

echo "[+] Done! To flash to Pixel 1:"
echo "    fastboot flash userdata ios16-root.simg"

