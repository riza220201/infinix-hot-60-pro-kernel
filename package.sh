#!/usr/bin/env bash
# package.sh — turn a gated build into the two deliverables.
#
#   ./package.sh <vanilla|ksunext>
#
#   out/<variant>/<DevSlug>-<variant>-<date>.zip       AnyKernel3, ROM-agnostic
#   out/<variant>/<DevSlug>-boot-<variant>-<date>.img  stock boot.img, rekernelled
#   (<DevSlug> is DEVICE_LABEL with non-alphanumerics dropped: InfinixHOT60Pro)
#
# ⚠ REFUSES TO RUN IF THE GATE HAS NOT PASSED for this variant. Packaging an
# ungated kernel is how an unbootable image reaches a user, and the sibling
# projects have a "self-consistent verify gate passing an unbootable image" entry
# for exactly this reason.
#
# Nothing device-specific is written here: the banner, the device names, the file
# prefix and the kernel format all resolve from device.conf. The itel RS4
# version of this script once printed its own `module_layout` literally into the
# installer, so a porter who changed device.conf shipped a zip that lied.
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

VARIANT="${1:-}"
[[ "$VARIANT" == "vanilla" || "$VARIANT" == "ksunext" ]] || \
  die "usage: ./package.sh <vanilla|ksunext>"

# shellcheck disable=SC1091
source "$PROJ/device.conf"
KERNEL_WS="${KERNEL_WS:-$PROJ/.build/kernel}"
OUT="$PROJ/out/$VARIANT"
DATE="$(date +%Y%m%d)"
DEVSLUG="$(echo "$DEVICE_LABEL" | tr -cd '[:alnum:]')"

# ── The gate must have passed ───────────────────────────────────────────────
for f in "$OUT/kmi-check.log" "$OUT/protect-check.log" "$OUT/import-check.log"; do
  [[ -f "$f" ]] || die "no $f — run ./build.sh $VARIANT first (packaging requires a gated build)"
done
grep -q "^RESULT: CLEAN" "$OUT/kmi-check.log" || \
  die "layer 1 did not pass for $VARIANT:
$(tail -3 "$OUT/kmi-check.log")"
grep -q "^RESULT: CLEAN" "$OUT/protect-check.log" || \
  die "layer 2 did not pass for $VARIANT:
$(tail -3 "$OUT/protect-check.log")"
grep -q "^RESULT: CLEAN" "$OUT/import-check.log" || \
  die "layer 3 did not pass for $VARIANT:
$(tail -3 "$OUT/import-check.log")"
say "gate logs confirm CLEAN for $VARIANT"

# ── Locate the built kernel ─────────────────────────────────────────────────
BIN="$KERNEL_WS/bazel-bin/common/kernel_aarch64"
case "$KERNEL_FMT" in
  lz4)  KIMG_NAME="Image.lz4" ;;
  gzip) KIMG_NAME="Image.gz"  ;;
  raw)  KIMG_NAME="Image"     ;;
  *)    die "device.conf KERNEL_FMT='$KERNEL_FMT' — expected lz4, gzip or raw" ;;
esac
KIMG="$(find "$BIN" -name "$KIMG_NAME" -print -quit 2>/dev/null || true)"
RAWIMG="$(find "$BIN" -name "Image" -print -quit 2>/dev/null || true)"
[[ -n "$RAWIMG" ]] || die "no Image under $BIN — build first"
KREL="$(cat "$(find "$BIN" -name kernel.release -print -quit)" 2>/dev/null || echo unknown)"
say "kernel.release = $KREL"

# 🔴 bazel-bin is SHARED between variants — it holds whatever was built LAST, while
#    the gate logs come from out/<variant>/. Package vanilla right after a ksunext
#    build and you ship the ROOT kernel under the vanilla name, with a vanilla gate
#    log vouching for it. Nothing downstream would catch it. The release string is
#    <VERSION>-$BRAND-<variant> (build.sh asserts it), so it names the variant
#    EXACTLY — match the whole suffix, not a substring that happens to be present.
KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_WS/common/Makefile")"
EXPECT_REL="${KSRC_VER}-${BRAND}-${VARIANT}"
[[ "$KREL" == "$EXPECT_REL" ]] || die "variant/image mismatch: packaging '$VARIANT' expects
   '$EXPECT_REL' but bazel-bin holds '$KREL'. bazel-bin is shared and holds the
   LAST build. Re-run: ./build.sh $VARIANT"
say "variant check ok — the image in bazel-bin is the $VARIANT build"

# Same shape as the itel RS4's installer string.
KSTRING="${DEVICE_LABEL} ${BRAND_FULL} (${VARIANT}) • ${KREL} • ${DATE}"

mkdir -p "$OUT"

# ── 1. AnyKernel3 zip (the ROM-agnostic deliverable) ────────────────────────
# It keeps whatever ramdisk is on the device and swaps only the kernel, so it
# works on stock and on any custom ROM.
AK="$PROJ/.build/ak3-$VARIANT"
rm -rf "$AK"; cp -r "$PROJ/anykernel" "$AK"
rm -f "$AK"/Image* "$AK"/zImage* 2>/dev/null || true

# Ship the RAW Image. On the itel RS4, shipping Image.gz and forcing
# IS_SLOT_DEVICE=1 made OrangeFox abort with "unable to determine slot"; the
# proven reference used the raw Image and IS_SLOT_DEVICE=auto.
cp "$RAWIMG" "$AK/Image"

# device.nameN lines, only for names that exist. Empty DEVICE_NAMES +
# do.devicecheck=0 means the zip installs anywhere, which is what we want until
# someone reads `getprop ro.product.device` off the phone.
NAMELINES=""; i=1
for n in $DEVICE_NAMES; do NAMELINES+="device.name${i}=${n}"$'\n'; i=$((i+1)); done
DEVCHECK=0; [[ -n "$DEVICE_NAMES" ]] && DEVCHECK=1

cat > "$AK/anykernel.sh" <<AKEOF
### AnyKernel3 Ramdisk Mod Script
## $DEVICE_LABEL ($DEVICE_SOC) — $VARIANT

properties() { '
kernel.string=${KSTRING}
do.devicecheck=${DEVCHECK}
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
${NAMELINES}supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# shell variables
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print "  ${DEVICE_LABEL}";
ui_print "  ${DEVICE_SOC}  ·  ${VARIANT}";
ui_print " ";
ui_print "  ${KREL}";
ui_print "  KMI module_layout ${MODULE_LAYOUT}";
ui_print "  gated against all stock modules: CLEAN";
ui_print " ";

split_boot;
flash_boot;
AKEOF

ZIP="$OUT/${DEVSLUG}-${VARIANT}-${DATE}.zip"
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '.git*' >/dev/null )
say "AnyKernel3 zip: $ZIP"

# ── 2. Prebuilt boot.img (stock firmware only) ──────────────────────────────
# ⚠ This carries the STOCK boot image's own structure. It is only useful if the
# bootloader will accept an image whose AVB hash no longer matches — which is an
# on-device question tools/device-probe.sh answers and nobody has answered yet.
if [[ -n "$KIMG" ]]; then
  W="$PROJ/.build/repack-$VARIANT"; rm -rf "$W"; mkdir -p "$W"
  cp "$STOCK_BOOT_IMG" "$W/boot.img"
  ( cd "$W" && magiskboot unpack boot.img >/dev/null 2>&1 || true )
  cp "$KIMG" "$W/kernel_new"
  # magiskboot repack re-compresses to whatever format it detected on unpack, so
  # hand it the RAW image and let it match the stock format itself.
  cp "$RAWIMG" "$W/kernel"
  ( cd "$W" && magiskboot repack boot.img "$OUT/${DEVSLUG}-boot-${VARIANT}-${DATE}.img" >/dev/null 2>&1 ) \
    && say "boot.img: $OUT/${DEVSLUG}-boot-${VARIANT}-${DATE}.img" \
    || echo "   (boot.img repack failed — the AnyKernel3 zip is the primary deliverable)"
else
  echo "   (no $KIMG_NAME built; skipping boot.img repack)"
fi

echo
say "SHA256"
( cd "$OUT" && sha256sum ./*.zip ./*.img 2>/dev/null || true )
