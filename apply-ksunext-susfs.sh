#!/usr/bin/env bash
# Integrate KernelSU-Next ("Wild" pershoot fork, SusFS in-driver) + SusFS into $KERNEL_SRC
# for the Infinix HOT 60 Pro+ (android16-6.12). Called by build.sh for the ksunext
# variant on a pristine git tree, which build.sh reverts afterwards.
#
# RECIPE — ported from itel-rs4-kernel/apply-ksunext-susfs.sh, which mirrors
# WildKernels/GKI_KernelSU_SUSFS. Two halves that MUST be the same SusFS version:
#   * KSU side:    pershoot/KernelSU-Next (SusFS *in-driver*, so NO `10_` patch —
#                  that patch is for stock KSU and fails 20+ hunks here)
#   * kernel side: simonpunk SusFS `50_add_susfs_in_gki-android16-6.12.patch`
#                  + its fs/ and include/linux/ files
#
# 🪤 DIFFERENCE FROM THE RS4: the RS4 symlinks drivers/kernelsu → $WILDKSU_SRC/kernel.
#    That cannot work here. This device builds with kleaf/bazel, which runs actions in
#    a sandbox where a symlink pointing outside the workspace does not resolve. We copy
#    the driver in as a REAL directory instead, and verify Kconfig is readable through
#    the copy rather than trusting the link.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
LOCKFILE="${LOCKFILE:-$PROJ/sources.lock}"
# shellcheck source=/dev/null
[[ -f "$LOCKFILE" ]] && source "$LOCKFILE"

WILDKSU_SRC="${WILDKSU_SRC:-$PROJ/.build/wildksu}"
WILDKSU_REF="${WILDKSU_REF:-}"
WILDKSU_VERBASE="${WILDKSU_VERBASE:-}"
WILDKSU_VER_EXPECT="${WILDKSU_VER_EXPECT:-}"
SUSFS="${SUSFS:-$PROJ/.build/susfs-612}"
SUSFS_REF="${SUSFS_REF:-}"
KVER="gki-android16-6.12"

say(){ echo "  [ksunext] $*"; }
die(){ echo "✗ [ksunext] $*" >&2; exit 1; }

[[ -f "$LOCKFILE" ]] || say "⚠ sources.lock not found — falling back to branch tips (NOT reproducible)"
[[ -n "$WILDKSU_REF" ]] || die "WILDKSU_REF is empty — pin the KSU commit in sources.lock first.
   An unpinned root driver is exactly what this project refuses to ship: the branch
   tip moves, and the kernel you gate is not the kernel you built last week."
[[ -d "$WILDKSU_SRC/.git" ]] || die "Wild KSU clone missing at $WILDKSU_SRC
   (git clone https://github.com/pershoot/KernelSU-Next $WILDKSU_SRC)"
[[ -d "$WILDKSU_SRC/kernel" ]] || die "$WILDKSU_SRC/kernel not found — wrong repo?"
if git -C "$WILDKSU_SRC" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  die "Wild KSU clone is shallow — the version rev-count would be wrong; re-clone full"
fi

# ── 1) pin SusFS, then pin the driver ────────────────────────────────────────────
if [[ -n "$SUSFS_REF" && -d "$SUSFS/.git" ]]; then
  git -C "$SUSFS" checkout -q -- . 2>/dev/null || true; git -C "$SUSFS" clean -fdq 2>/dev/null || true
  git -C "$SUSFS" checkout -q "$SUSFS_REF" 2>/dev/null \
    || die "SusFS ref ${SUSFS_REF:0:12} not in $SUSFS — fetch it or fix sources.lock"
  say "pin SusFS (simonpunk $KVER) @ ${SUSFS_REF:0:12}"
fi
PATCH50="$SUSFS/kernel_patches/50_add_susfs_in_${KVER}.patch"
[[ -f "$PATCH50" ]] || die "susfs 50_ patch missing at $PATCH50"

say "pin Wild KSU (pershoot KernelSU-Next) @ ${WILDKSU_REF:0:12}"
git -C "$WILDKSU_SRC" checkout -q -- . 2>/dev/null || true; git -C "$WILDKSU_SRC" clean -fdq
git -C "$WILDKSU_SRC" checkout -q "$WILDKSU_REF" 2>/dev/null \
  || git -C "$WILDKSU_SRC" checkout -q "origin/$WILDKSU_REF" 2>/dev/null \
  || die "ref $WILDKSU_REF not in clone — fetch it or fix sources.lock"

# Version = 30000 + rev-count(anchor). Pinning detaches HEAD, so the anchor is pinned
# separately; the manager APK must be >= this number or root silently does not work.
KVCOMMIT="${WILDKSU_VERBASE:-HEAD}"
KVERNUM=$(( 30000 + $(git -C "$WILDKSU_SRC" rev-list --count "$KVCOMMIT") ))
[[ -z "$WILDKSU_VER_EXPECT" || "$KVERNUM" == "$WILDKSU_VER_EXPECT" ]] \
  || die "KSU version drift: computed $KVERNUM but sources.lock expects $WILDKSU_VER_EXPECT
   — WILDKSU_REF/VERBASE moved; reconcile sources.lock (and the package banner) first."
KSUN_TAG=$(git -C "$WILDKSU_SRC" describe --tags --abbrev=0 --match 'v[0-9]*' \
           --exclude '*-legacy' "$KVCOMMIT" 2>/dev/null || echo "v?")
say "Wild KSU-Next $KSUN_TAG, reported version = $KVERNUM (the $KSUN_TAG manager binds it)"

# static.patch de-statics three selinux_hide fns so the SusFS hooks link. Trees that
# define SUSFS_EXPORT already do it themselves and the patch no longer applies.
if grep -q '^#define SUSFS_EXPORT' "$WILDKSU_SRC/kernel/feature/selinux_hide.c" 2>/dev/null; then
  say "static.patch NOT needed: this tree de-statics selinux_hide itself (SUSFS_EXPORT)"
elif [[ -f "$PROJ/patches/ksunext-static.patch" ]]; then
  say "apply WildKernels static.patch (de-static selinux_hide fns)"
  ( cd "$WILDKSU_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PROJ/patches/ksunext-static.patch" ) \
    || die "static.patch failed on $WILDKSU_SRC"
else
  die "this tree lacks SUSFS_EXPORT and no patches/ksunext-static.patch is present —
   the SusFS selinux hooks would fail to link. Fetch the WildKernels static.patch."
fi

# ── 2) wire the driver in as a REAL directory (see the kleaf note at the top) ─────
say "copy drivers/kernelsu ← $WILDKSU_SRC/kernel  (real dir, not a symlink: bazel sandbox)"
rm -rf "$KERNEL_SRC/drivers/kernelsu"
cp -a "$WILDKSU_SRC/kernel" "$KERNEL_SRC/drivers/kernelsu"
rm -rf "$KERNEL_SRC/drivers/kernelsu/.git"
[[ -f "$KERNEL_SRC/drivers/kernelsu/Kconfig" ]] || die "drivers/kernelsu Kconfig missing after copy"
[[ ! -L "$KERNEL_SRC/drivers/kernelsu" ]] || die "drivers/kernelsu is a symlink — bazel will not resolve it"

# 🪤 The driver tree contains git-stored symlinks that point OUT of kernel/ — at the
#    pinned commit, `kernel/include/uapi -> ../../uapi`, i.e. the repo root's uapi/.
#    The RS4 symlinks the whole kernel/ dir, so its sibling uapi/ is still reachable
#    and this never comes up. We copy, `cp -a` faithfully preserves the link, and it
#    then dangles — ../../uapi resolves to drivers/uapi, which does not exist. The
#    build fails deep inside bazel with a bare
#        policy/allowlist.h:6:10: fatal error: 'uapi/app_profile.h' file not found
#    Materialise every escaping link against the SOURCE repo so the copy is
#    self-contained, and fail loudly if one cannot be resolved.
while IFS= read -r lnk; do
  [[ -n "$lnk" ]] || continue
  rel="${lnk#$KERNEL_SRC/drivers/kernelsu/}"
  src_target="$(cd "$(dirname "$WILDKSU_SRC/kernel/$rel")" && readlink -f "$(basename "$(readlink "$lnk")")" 2>/dev/null || true)"
  [[ -z "$src_target" ]] && src_target="$(readlink -f "$WILDKSU_SRC/kernel/$rel" 2>/dev/null || true)"
  [[ -n "$src_target" && -e "$src_target" ]] \
    || die "cannot resolve symlink $rel -> $(readlink "$lnk") against $WILDKSU_SRC"
  rm -f "$lnk"; cp -aL "$src_target" "$lnk"
  say "materialised out-of-tree symlink: $rel -> $(basename "$src_target")/"
done < <(find "$KERNEL_SRC/drivers/kernelsu" -type l 2>/dev/null)

# Nothing may dangle after this: a broken include path fails 7 minutes into the build.
BROKEN=$(find "$KERNEL_SRC/drivers/kernelsu" -xtype l 2>/dev/null | head -3)
[[ -z "$BROKEN" ]] || die "dangling symlinks remain under drivers/kernelsu:
$BROKEN"
[[ -f "$KERNEL_SRC/drivers/kernelsu/include/uapi/app_profile.h" ]] \
  || die "drivers/kernelsu/include/uapi/app_profile.h missing — the uapi headers did
   not come across; the build would fail inside bazel with a bare 'file not found'."

# 🔴 The driver's Kbuild derives KSU_VERSION (30000 + rev-count) and KSU_VERSION_TAG
#    (git describe) from ITS OWN git repo, and silently falls back to 1 / "v0.0.1"
#    when it finds none. The copy above has no .git, so every v1/v2 ksunext kernel
#    reported version 1 — the manager showed "v0.0.1 (1-4)" on the tester's phone —
#    while this script logged "reported version = 33312" about the SOURCE clone.
#    Pin the values that probe would have computed, before it runs; build.sh then
#    asserts the build log says so. A version check must read what was BUILT.
KBD="$KERNEL_SRC/drivers/kernelsu/Kbuild"
grep -q '^# Check if this is a git repository' "$KBD" \
  || die "drivers/kernelsu/Kbuild: the git-version probe moved — re-check how it derives KSU_VERSION"
PIN="# [ksunext] pinned by apply-ksunext-susfs.sh — the driver is copied in without .git
KSU_GIT_VERSION := $((KVERNUM - 30000))
KSU_GIT_TAG := $KSUN_TAG
KSU_GIT_VERSION_VALID := 1
"
PIN="$PIN" awk '/^# Check if this is a git repository/ { printf "%s", ENVIRON["PIN"] } { print }' \
  "$KBD" > "$KBD.pinned" && mv "$KBD.pinned" "$KBD"
grep -qx "KSU_GIT_VERSION := $((KVERNUM - 30000))" "$KBD" && grep -qx "KSU_GIT_TAG := $KSUN_TAG" "$KBD" \
  || die "failed to pin KSU_GIT_VERSION/TAG in $KBD"
say "pinned driver version: KSU_VERSION=$KVERNUM, tag $KSUN_TAG (no .git in the copied tree)"

DMK="$KERNEL_SRC/drivers/Makefile"; DKC="$KERNEL_SRC/drivers/Kconfig"
grep -q 'kernelsu' "$DMK" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DMK"
grep -q 'drivers/kernelsu/Kconfig' "$DKC" \
  || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$DKC"

# ── 3) SusFS kernel side ─────────────────────────────────────────────────────────
# Version is READ from source, never hardcoded — a banner that advertises a SusFS
# version the kernel does not contain is how a release note lies about its artifact.
SUSFS_VER=$(sed -n 's/.*#define SUSFS_VERSION[[:space:]]*"\(v[0-9.]*\)".*/\1/p' \
            "$SUSFS/kernel_patches/include/linux/susfs.h" 2>/dev/null | head -1 || true)
[[ -n "$SUSFS_VER" ]] || SUSFS_VER="unknown"
say "copy susfs fs/ + include/linux/ headers ($SUSFS_VER)"
cp "$SUSFS/kernel_patches/fs/"*            "$KERNEL_SRC/fs/"
cp "$SUSFS/kernel_patches/include/linux/"* "$KERNEL_SRC/include/linux/"

say "apply $(basename "$PATCH50") at kernel root"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH50" ) \
  || die "50_ patch failed — inspect .rej under $KERNEL_SRC"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] \
  || die "50_ patch left .rej files — fixup needed before this can be trusted"

say "Wild KSU-Next ${WILDKSU_REF:0:12} (v$KVERNUM) + SusFS $SUSFS_VER integrated (no 10_ — SusFS in-driver)"
