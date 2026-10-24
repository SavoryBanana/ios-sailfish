#!/usr/bin/env bash
# deploy-sweetgl-live.sh: Inject sweetgl.dylib directly into phone userdata without wiping.
# Uses NBD over ADB so the host Linux kernel (which supports HFS+) performs the write.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] This script requires root permissions to mount HFS+ on host."
    echo "    Usage: sudo ./deploy-sweetgl-live.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYLIB="${HERE}/staging/sweetgl/sweetgl.dylib"

if [ ! -f "${DYLIB}" ]; then
    echo "[-] Error: ${DYLIB} not found."
    exit 1
fi

echo "[*] Ensuring NBD module is loaded on host..."
modprobe nbd max_part=8 || true

echo "[*] Pushing static NBD server to phone..."
su - "$REAL_USER" -c "adb push '${HERE}/tools/nbd-server-arm64' /tmp/nbd-server >/dev/null"
su - "$REAL_USER" -c "adb shell chmod +x /tmp/nbd-server"

echo "[*] Forwarding NBD port 10809 over ADB..."
su - "$REAL_USER" -c "adb forward tcp:10809 tcp:10809"

echo "[*] Launching NBD server on phone for /dev/block/sda35..."
su - "$REAL_USER" -c "adb shell 'killall nbd-server 2>/dev/null || true'"
su - "$REAL_USER" -c "adb shell '/tmp/nbd-server /dev/block/sda35 10809 >/tmp/nbd.log 2>&1 &' &"
sleep 1

echo "[*] Connecting host /dev/nbd0 to phone over ADB..."
qemu-nbd -d /dev/nbd0 2>/dev/null || true
qemu-nbd -c /dev/nbd0 nbd://127.0.0.1:10809

MNT=$(mktemp -d /tmp/pixel-hfs.XXXXXX)
cleanup() {
    echo "[*] Cleaning up..."
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    qemu-nbd -d /dev/nbd0 2>/dev/null || true
    su - "$REAL_USER" -c "adb forward --remove tcp:10809" 2>/dev/null || true
}
trap cleanup EXIT

echo "[*] Mounting phone's HFS+ filesystem on host..."
mount -t hfsplus -o rw,force /dev/nbd0 "$MNT"

echo "[*] Injecting sweetgl.dylib to /usr/lib/sweetgl.dylib..."
mkdir -p "$MNT/usr/lib"
cp "$DYLIB" "$MNT/usr/lib/sweetgl.dylib"
chmod 755 "$MNT/usr/lib/sweetgl.dylib"
chown 0:0 "$MNT/usr/lib/sweetgl.dylib"
sync

echo "[+] Verification:"
ls -lh "$MNT/usr/lib/sweetgl.dylib"

echo "[*] Safely unmounting..."
umount "$MNT"
qemu-nbd -d /dev/nbd0
trap - EXIT
rmdir "$MNT"
su - "$REAL_USER" -c "adb forward --remove tcp:10809" 2>/dev/null || true

echo ""
echo "============================================================"
echo "  sweetgl.dylib deployed to phone successfully!"
echo "  All user data and data migration preserved."
echo "============================================================"
echo "[*] Next, reboot the Pixel to bootloader and boot iOS:"
echo "    adb reboot bootloader"
echo "    fastboot boot shim/out/pixel-boot.img"

