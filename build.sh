#!/usr/bin/env bash
# build.sh — build a kernel variant for this device and gate it against the KMI.
#
#   ./build.sh vanilla            stock ACK + this project's KMI-safe fragments
#   ./build.sh vanilla --stock    pure ACK, zero fragments (the control build)
#   ./build.sh ksunext            vanilla + KernelSU-Next + SusFS
#
# Flags:
#   --stock        no defconfig fragments at all. Use this for the first build on
#                  a new source branch: it measures ONE thing — whether that
#                  branch reproduces the device's KMI — instead of conflating it
#                  with whatever we changed.
#   --gate-only    skip the build, re-run the gates against the last outputs.
#   --jobs N       cap bazel's parallelism (RAM-bound boxes).
#
# The build system here is **kleaf/Bazel**, not `make` + `build.config`. Nothing
# from the itel RS4 project's build.sh transfers; only its discipline does.
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

# ── Arguments ───────────────────────────────────────────────────────────────
VARIANT=""; STOCK=0; GATE_ONLY=0; JOBS=""; LTO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    vanilla|ksunext) VARIANT="$1" ;;
    --stock)         STOCK=1 ;;
    --lto)           shift; LTO="${1:-}" ;;
    --gate-only)     GATE_ONLY=1 ;;
    --jobs)          shift; JOBS="${1:-}" ;;
    *)               die "unknown argument: $1" ;;
  esac
  shift
done
[[ -n "$VARIANT" ]] || die "usage: ./build.sh <vanilla|ksunext> [--stock] [--gate-only] [--jobs N]"

# ── device.conf ─────────────────────────────────────────────────────────────
[[ -f "$PROJ/device.conf" ]] || die "no device.conf"
# shellcheck disable=SC1091
source "$PROJ/device.conf"
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock"

# Refuse in seconds, not after an hour of compiling.
[[ "${MODULE_LAYOUT:-}" =~ ^0x[0-9a-fA-F]{8}$ ]] || die \
"device.conf MODULE_LAYOUT is empty or not an 8-digit CRC ('${MODULE_LAYOUT:-}').
 Obtain it from any module this device ships:
   modprobe --dump-modversions <vendor>.ko | awk '\$2==\"module_layout\"{print \$1}'"

KERNEL_WS="${KERNEL_WS:-$PROJ/.build/kernel}"
KMI_REF_TREE="${KMI_REF_TREE:-$PROJ/.build/kmi-ref}"

# A build path containing a space breaks the kernel Makefile, pkg-config, meson
# and Kbuild — each with a different message, none of which names the variable.
for v in PROJ KERNEL_WS KMI_REF_TREE; do
  case "${!v}" in
    *[[:space:]]*|*:*) die "$v contains a space or a colon: '${!v}' — move it." ;;
  esac
done

# ── Preflight ───────────────────────────────────────────────────────────────
say "preflight"

# Check for a marker FILE. `git -C <dir> log` silently walks UP to the parent
# repo when <dir> has no .git, which makes an empty checkout look successful.
[[ -f "$KERNEL_WS/common/Makefile" ]] || die \
  "no kernel source at $KERNEL_WS/common (expected common/Makefile).
   Run:  repo init -u $KERNEL_MANIFEST_URL -b $KERNEL_MANIFEST_BRANCH --depth=1 && repo sync -c"
[[ -x "$KERNEL_WS/tools/bazel" ]] || die "no $KERNEL_WS/tools/bazel — the manifest linkfiles are missing"

# Refuse to build off a drifted source. `repo sync` tracks the branch and will
# fast-forward `common` past the pin without leaving the tree dirty — on
# 2026-09-29 that silently moved us one commit and restructured
# fs/proc/task_mmu.c by 579 lines. A build whose source is not the source the
# lockfile names is not reproducible, and the KMI gate cannot see the difference.
if [[ -n "${KERNEL_COMMON_REF:-}" ]]; then
  _cur="$(git -C "$KERNEL_WS/common" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$_cur" != "$KERNEL_COMMON_REF" ]]; then
    die "common is at ${_cur:0:9} but sources.lock pins ${KERNEL_COMMON_REF:0:9}.
     Restore it:  git -C $KERNEL_WS/common checkout $KERNEL_COMMON_REF
     or update sources.lock deliberately — but do not build off an unrecorded tree."
  fi
fi

KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_WS/common/Makefile")"
KSRC_REF="$(git -C "$KERNEL_WS/common" rev-parse --short HEAD 2>/dev/null || echo unknown)"
KMI_GEN="$(awk -F= '/^KMI_GENERATION/{print $2}' "$KERNEL_WS/common/build.config.constants")"
echo "   source        : $KSRC_VER @ $KSRC_REF  (KMI_GENERATION=$KMI_GEN)"
echo "   KMI target    : $MODULE_LAYOUT"

# The AOSP hermetic python3 that lands on PATH during a build lacks pyelftools;
# find one that can actually parse an ELF and use it for the gates.
SYSPY=""
for c in python3 /usr/bin/python3; do
  "$c" -c 'import elftools' >/dev/null 2>&1 && { SYSPY="$c"; break; }
done
[[ -n "$SYSPY" ]] || die "no python3 with pyelftools — the KMI gate cannot run (pip install pyelftools)"
echo "   gate python   : $SYSPY"

NKO="$(find "$KMI_REF_TREE" -name '*.ko' 2>/dev/null | wc -l)"
[[ "$NKO" -gt 0 ]] || die \
  "no modules under $KMI_REF_TREE — run tools/extract-device-material.sh first.
   A gate with an empty reference set cannot fail, which is worse than no gate."
echo "   KMI reference : $NKO modules"

# ── Source hygiene ──────────────────────────────────────────────────────────
# Every build starts from a pristine tree plus transient patches, so a dirty
# tree is always leftovers from a crashed run — reset it rather than wedging the
# next build. KEEP_DIRTY=1 opts into abort-and-inspect for local hacking.
prepare_source() {
  local dirty
  dirty="$(git -C "$KERNEL_WS/common" status --porcelain 2>/dev/null | head -5)"
  if [[ -n "$dirty" ]]; then
    if [[ "${KEEP_DIRTY:-0}" == "1" ]]; then
      die "common/ is dirty and KEEP_DIRTY=1:
$dirty"
    fi
    echo "   common/ was dirty — resetting to pristine (leftovers from a crashed run)"
    git -C "$KERNEL_WS/common" checkout -- . 2>/dev/null || true
    git -C "$KERNEL_WS/common" clean -fd >/dev/null 2>&1 || true
  fi
}
cleanup() {
  local rc=$?
  git -C "$KERNEL_WS/common" checkout -- . 2>/dev/null || true
  git -C "$KERNEL_WS/common" clean -fd >/dev/null 2>&1 || true
  exit $rc
}

OUT="$PROJ/out/$VARIANT"
mkdir -p "$OUT"

if [[ "$GATE_ONLY" == 0 ]]; then
  prepare_source
  trap cleanup EXIT

  # ── ksunext: KernelSU-Next + SusFS into the now-pristine tree ─────────────
  # Runs AFTER prepare_source (which guarantees pristine) and BEFORE configure, so
  # the Kconfig the fragment selects actually exists. The EXIT trap git-reverts the
  # tree afterwards, so a ksunext build never leaks into the next vanilla one.
  if [[ "$VARIANT" == "ksunext" && "$STOCK" == 0 ]]; then
    say "integrating KernelSU-Next + SusFS"
    KERNEL_SRC="$KERNEL_WS/common" PROJ="$PROJ" LOCKFILE="$PROJ/sources.lock" \
      "$PROJ/apply-ksunext-susfs.sh" || die "ksunext integration failed — see above"
  fi

  # ── Configure ─────────────────────────────────────────────────────────────
  BAZEL_ARGS=()
  if [[ "$STOCK" == 1 ]]; then
    say "config: PURE ACK — no fragments (control build)"
  else
    FRAG="$PROJ/config/${VARIANT}_defconfig"
    [[ -f "$FRAG" ]] || die "no $FRAG (use --stock to build without fragments)"
    # kleaf needs the fragment inside the workspace and exported by a BUILD file.
    install -D -m644 "$FRAG" "$KERNEL_WS/common/${VARIANT}_defconfig"
    # Keep our scratch fragment out of git's view. (It is NOT the cause of the
    # "maybe-dirty" release string — I guessed that and was wrong; see the stamp
    # note below. This is just hygiene so `git status` stays readable.)
    EXC="$KERNEL_WS/common/.git/info/exclude"
    if [[ -f "$EXC" ]] && ! grep -qx "${VARIANT}_defconfig" "$EXC"; then
      echo "${VARIANT}_defconfig" >> "$EXC"
    fi
    say "config: gki_defconfig + config/${VARIANT}_defconfig"
    BAZEL_ARGS+=("--defconfig_fragment=//common:${VARIANT}_defconfig")
  fi
  [[ -n "$JOBS" ]] && BAZEL_ARGS+=("--jobs=$JOBS")
  # --lto is an EXPERIMENT KNOB, not a tuning one. gki_defconfig ships LTO_NONE
  # on android14-6.1+ because kCFI no longer needs whole-program LTO, and the
  # device's own extracted config confirms LTO_NONE. Anything else is a
  # deliberate departure from the shipped configuration — which on 5.10 was
  # known to move module_layout and break every vendor module. Whether that is
  # still true on 6.12 is a measurement, and this flag is how to take it.
  if [[ -n "$LTO" ]]; then
    BAZEL_ARGS+=("--lto=$LTO")
    say "⚠ LTO OVERRIDE: --lto=$LTO  (stock is LTO_NONE; expect the gate to judge it)"
    OUT="$OUT-lto-$LTO"; mkdir -p "$OUT"
  fi

  # ── Build ─────────────────────────────────────────────────────────────────
  # LTO is OFF by default in gki_defconfig on android14-6.1+ (kCFI does not need
  # it), and the device's own extracted config confirms LTO_NONE — so we do NOT
  # pass --lto. Matching the stock config is the point.
  #
  # --config=stamp embeds the real SCM version. Without it kleaf emits a literal
  # placeholder — build/kernel/kleaf/impl/stamp.bzl:63 is
  #     stable_scmversion_cmd = "echo '-maybe-dirty'"
  # so "6.12.38-android16-5-maybe-dirty-4k" never meant the tree was dirty; it
  # meant stamping was off and kleaf had not looked. Stock reads
  # "…-gb575a0b6e647-ab14355190-4k", so a real -g<sha> is the honest match.
  # ── v1 ships with the stock kleaf stamp ────────────────────────────────────
  # This gives "6.12.38-android16-5-g<sha>-dirty-RivalAbadi-<variant>-4k". The
  # "-dirty" is accurate on ksunext (that tree really does carry the KSU driver and
  # the SusFS patch) but it is not a pretty release string.
  #
  # tools/workspace-status-clean.sh removes the "-g<sha>-dirty" field and is written,
  # path-corrected and verified to emit the right workspace status — but it is NOT
  # wired here, DELIBERATELY: the v1 zips that shipped were built with the stamp
  # below, and the committed recipe must reproduce the artifact that shipped. Wire it
  # for v2, rebuild both variants, and repackage together. See JOURNAL.md.
  BAZEL_ARGS+=("--config=stamp")
  say "build: //common:kernel_aarch64"
  ( cd "$KERNEL_WS" && ./tools/bazel build "${BAZEL_ARGS[@]}" //common:kernel_aarch64 ) \
    2>&1 | tee "$OUT/build.log"
fi

# ── Locate the artifacts ────────────────────────────────────────────────────
BIN="$KERNEL_WS/bazel-bin/common/kernel_aarch64"
SYMVERS="$(find "$BIN" -name vmlinux.symvers -print -quit 2>/dev/null || true)"
[[ -n "$SYMVERS" ]] || die "no vmlinux.symvers under $BIN — did the build produce anything?"
SYMBOLLIST="$(find "$KERNEL_WS/bazel-bin/common" -name 'abi_symbollist' -print -quit 2>/dev/null || true)"

KREL="$(find "$BIN" -name 'kernel.release' -print -quit 2>/dev/null || true)"
[[ -n "$KREL" ]] && echo "   kernel.release: $(cat "$KREL")"

# ── Gate ────────────────────────────────────────────────────────────────────
# Layer 1 — do the CRCs agree. Layer 3 — will every import actually resolve, and
# is it permitted. Layer 1 alone calls a kernel with too narrow a symbol list
# CLEAN, so both run and both must pass.
# 🪤 `set -euo pipefail` aborts the script the moment layer 1 exits non-zero,
#    so a FAILING layer 1 meant layer 3 never ran and its log read "did not run".
#    A diagnostic that disappears exactly when the build is broken is the one
#    time you need it. Both layers now always run; the verdict is computed after.
set +e
say "KMI gate — layer 1: symbol CRCs vs $NKO stock modules"
"$SYSPY" "$PROJ/lib/kmi_check.py" "$SYMVERS" "$KMI_REF_TREE" | tee "$OUT/kmi-check.log"
L1=${PIPESTATUS[0]}

say "KMI gate — layer 3: import accounting"
if [[ -n "$SYMBOLLIST" ]]; then
  "$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_TREE" "$SYMBOLLIST" | tee "$OUT/import-check.log"
else
  echo "   (no abi_symbollist found — running without the permitted-import check)"
  "$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_TREE" | tee "$OUT/import-check.log"
fi
L3=${PIPESTATUS[0]}

set -e
echo
if [[ "$L1" == 0 && "$L3" == 0 ]]; then
  echo "GATE: PASS — layer 1 clean, layer 3 clean."
else
  echo "GATE: FAIL — layer1=$L1 layer3=$L3  (1=broken 2=vacuous 3=wrong reference set)"
  exit 1
fi
