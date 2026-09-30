#!/usr/bin/env bash
# Answer the questions the stock images cannot, from the running phone.
#
# READ-ONLY. Every command below is a getprop / ls / cat. Nothing is written,
# pushed, remounted, flashed or rebooted. Run it with the phone attached and
# USB debugging on:
#
#   tools/device-probe.sh [> .build/device-probe.txt]
#
# It answers exactly the three things left open at project bootstrap, plus one
# that turned out to matter more than expected:
#
#   1. the model codename        -> device.conf DEVICE_NAMES (every supplied
#                                   image is the Transsion generic vendor `tssi`
#                                   and carries no per-model name)
#   2. bootloader / AVB state    -> decides whether the prebuilt-boot.img
#                                   deliverable is real, or whether AnyKernel3
#                                   is the only path
#   3. recovery layout           -> is there a DEDICATED recovery partition? That
#                                   is what makes the itel RS4's
#                                   "built-in ZRAM bricks OrangeFox" trap
#                                   relevant here or irrelevant. Do not carry
#                                   that conclusion across devices; measure it.
#   4. /system_dlkm              -> which GKI modules this phone actually loads,
#                                   and whether they are signed. Three GKI
#                                   modules (libarc4, rfkill, zsmalloc) already
#                                   turned up inside vendor_dlkm carrying
#                                   Google's key; a custom kernel has a different
#                                   key, and a PROTECTED module that fails
#                                   signature check is refused with -EACCES.
#                                   This is the size of that risk, measured.
set -uo pipefail

ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB="/mnt/external_nvme/android-sdk/platform-tools/adb"
command -v "$ADB" >/dev/null 2>&1 || { echo "no adb found — set ADB=/path/to/adb"; exit 1; }

"$ADB" get-state >/dev/null 2>&1 || {
  echo "no device in adb. Plug the phone in, enable USB debugging, accept the"
  echo "RSA prompt, then re-run. ('$ADB devices' should list it as 'device'.)"
  exit 1
}

sh() { "$ADB" shell "$@" 2>&1; }
hdr() { echo; echo "=== $* ==="; }

echo "device-probe  $(date -Iseconds)"
echo "adb: $("$ADB" version | head -1)"
"$ADB" devices -l | sed -n '2p'

hdr "1. identity  -> device.conf DEVICE_NAMES"
for p in ro.product.device ro.product.name ro.product.model ro.product.brand \
         ro.product.manufacturer ro.build.fingerprint ro.build.version.release \
         ro.build.version.security_patch ro.board.platform ro.hardware; do
  printf '  %-36s %s\n' "$p" "$(sh getprop $p)"
done

hdr "2. bootloader / AVB  -> can we flash an unsigned boot.img?"
for p in ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state \
         ro.boot.veritymode ro.boot.vbmeta.digest ro.boot.slot_suffix \
         ro.boot.hardware ro.secure ro.debuggable; do
  printf '  %-36s %s\n' "$p" "$(sh getprop $p)"
done
echo "  interpretation:"
echo "    verifiedbootstate=green + flash.locked=1 -> locked; a repacked boot.img"
echo "    will NOT boot and AnyKernel3 is the only path."
echo "    orange/unlocked -> both deliverables are viable."

hdr "3. partition layout  -> is recovery its own partition?"
echo "  (a dedicated recovery partition means recovery does NOT share boot's"
echo "   kernel, which is what made built-in ZRAM brick recovery on the itel RS4)"
sh 'ls -l /dev/block/by-name/ 2>/dev/null | grep -iE "recovery|boot|vendor_dlkm|system_dlkm|init_boot|vbmeta" || echo "  (need root to list by-name; try: adb shell su -c '"'"'ls -l /dev/block/by-name/'"'"')"'
echo "  ramdisk/recovery hints:"
printf '  %-36s %s\n' "ro.boot.hwver" "$(sh getprop ro.boot.hwver)"
printf '  %-36s %s\n' "recovery_mode prop" "$(sh getprop ro.boot.mode)"

hdr "4. running kernel"
sh cat /proc/version
printf '  %-36s %s\n' "uname -r" "$(sh uname -r)"
echo "  (must read 6.12.38-android16-5-gb575a0b6e647-ab14355190-4k on stock;"
echo "   anything else means this phone is not on the firmware we characterised)"

hdr "5. /system_dlkm — the GKI module set and its signing"
sh 'ls /system_dlkm/lib/modules/*/ 2>/dev/null | head -40 || echo "  (not mounted or not readable without root)"'
echo "  count:"
sh 'find /system_dlkm -name "*.ko" 2>/dev/null | wc -l'
echo "  modules.load (what actually gets loaded):"
sh 'cat /system_dlkm/lib/modules/*/modules.load 2>/dev/null | head -20'

hdr "6. loaded modules right now"
sh 'cat /proc/modules 2>/dev/null | wc -l'
echo "  (stock should be ~349: 168 vendor_dlkm + 181 vendor_boot from modules.load)"

hdr "7. config availability"
sh 'ls -l /proc/config.gz 2>/dev/null || echo "  (no /proc/config.gz — we already have the config from boot.img ikconfig)"'

echo
echo "done — nothing was written to the device."
