#!/usr/bin/env bash
# Regenerate every device-derived input in .build/ from the four stock images at
# the project root. Nothing under .build/ is hand-placed: if a number in the
# journal came from a module or from the stock config, this script is how it got
# there, and re-running it is how anyone checks.
#
#   boot.img         -> .build/ikconfig/stock.config   (CONFIG_IKCONFIG blob)
#                    -> .build/stock/kernel            (decompressed Image)
#   vendor_dlkm.img  -> .build/kmi-ref/vendor_dlkm/*.ko
#   vendor_boot.img  -> .build/kmi-ref/vendor_boot/*.ko  + dtb + bootconfig
#
# Then harvest the KMI reference off those modules. Re-run after replacing ANY
# image — and re-point every gate that names it, because a stale reference set
# cannot fail.
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ"
B="$PROJ/.build"
need() { command -v "$1" >/dev/null || { echo "missing tool: $1 ($2)"; exit 1; }; }
need magiskboot "unpack boot.img"
need unpack_bootimg "unpack vendor_boot.img"
need fsck.erofs "extract vendor_dlkm.img"
need cpio "unpack the vendor ramdisk"
command -v lz4 >/dev/null || command -v unlz4 >/dev/null || { echo "missing tool: lz4"; exit 1; }
LZ4="$(command -v lz4 || command -v unlz4)"

for img in boot.img vendor_boot.img vendor_dlkm.img; do
  [[ -f "$PROJ/$img" ]] || { echo "missing $PROJ/$img"; exit 1; }
done

rm -rf "$B/stock" "$B/kmi-ref" "$B/ikconfig"
mkdir -p "$B/stock" "$B/kmi-ref/vendor_dlkm" "$B/kmi-ref/vendor_boot" "$B/ikconfig"

# ── boot.img: the kernel, and the config it embeds ──────────────────────────
echo "== boot.img"
( cd "$B/stock" && cp "$PROJ/boot.img" . && magiskboot unpack boot.img >unpack.log 2>&1 || true )
grep -E "HEADER_VER|KERNEL_FMT|KERNEL_SZ|RAMDISK_SZ" "$B/stock/unpack.log" || true
[[ -f "$B/stock/kernel" ]] || { echo "magiskboot produced no kernel"; exit 1; }
python3 - "$B/stock/kernel" "$B/ikconfig/stock.config" <<'PY'
import gzip, sys
blob = open(sys.argv[1], 'rb').read()
s, e = blob.find(b'IKCFG_ST'), blob.find(b'IKCFG_ED')
if s < 0 or e < 0:
    sys.exit("no IKCFG_ST/ED markers — this kernel was not built with CONFIG_IKCONFIG")
open(sys.argv[2], 'wb').write(gzip.decompress(blob[s + 8:e]))
PY
# The config is the whole reason the KMI is reproducible. If the load-bearing
# options are not in it, we extracted the wrong thing — say so now, not after a
# build.
for opt in CONFIG_CFI_CLANG=y CONFIG_MODVERSIONS=y; do
  grep -qx "$opt" "$B/ikconfig/stock.config" || { echo "stock.config lacks $opt — refusing"; exit 1; }
done
echo "   stock.config: $(grep -c '^CONFIG_' "$B/ikconfig/stock.config") set options"
# grep the file directly rather than `strings | grep -m1`: under `pipefail`,
# grep exiting at the first match SIGPIPEs strings and fails the whole script.
grep -aom1 'Linux version [[:print:]]*' "$B/stock/kernel" > "$B/stock/kernel-release.txt" \
  || { echo "no 'Linux version' banner in the unpacked kernel"; exit 1; }
cat "$B/stock/kernel-release.txt"

# ── vendor_dlkm.img: one of the two module sets ─────────────────────────────
echo "== vendor_dlkm.img"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fsck.erofs --extract="$tmp/vdlkm" "$PROJ/vendor_dlkm.img" >/dev/null 2>&1
find "$tmp/vdlkm" -name '*.ko' -exec cp -t "$B/kmi-ref/vendor_dlkm/" {} +
for f in modules.load modules.dep modules.alias modules.softdep; do
  src="$(find "$tmp/vdlkm" -name "$f" -print -quit)"
  [[ -n "$src" ]] && cp "$src" "$B/kmi-ref/vendor_dlkm.$f"
done
echo "   $(ls "$B/kmi-ref/vendor_dlkm" | wc -l) modules"

# ── vendor_boot.img: the other module set, plus the DTB ─────────────────────
echo "== vendor_boot.img"
mkdir -p "$tmp/vboot"
unpack_bootimg --boot_img "$PROJ/vendor_boot.img" --out "$tmp/vboot" > "$B/stock/vendor_boot-header.txt"
grep -E "header version|page size|command line|dtb size|bootconfig" "$B/stock/vendor_boot-header.txt" || true
cp "$tmp/vboot/dtb" "$B/stock/vendor_boot.dtb" 2>/dev/null || true
cp "$tmp/vboot/bootconfig" "$B/stock/vendor_boot.bootconfig" 2>/dev/null || true
mkdir -p "$tmp/rd"
( cd "$tmp/rd" && "$LZ4" -dc "$tmp/vboot/vendor_ramdisk00" 2>/dev/null | cpio -idm --quiet )
find "$tmp/rd" -name '*.ko' -exec cp -t "$B/kmi-ref/vendor_boot/" {} +
for f in modules.load modules.dep modules.alias modules.softdep modules.blocklist; do
  src="$(find "$tmp/rd/lib/modules" -name "$f" -print -quit 2>/dev/null || true)"
  [[ -n "$src" ]] && cp "$src" "$B/kmi-ref/vendor_boot.$f"
done
echo "   $(ls "$B/kmi-ref/vendor_boot" | wc -l) modules"

# ── the reference every build is gated against ──────────────────────────────
echo "== harvesting the KMI reference"
python3 "$PROJ/tools/harvest-kmi-ref.py" "$B/kmi-ref" "$B/kmi-ref/stock-derived.symvers"
