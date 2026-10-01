#!/usr/bin/env bash
# Apply this project's source modifications (patches/series) to $KERNEL_SRC.
# Called by build.sh for every non-stock variant, on the pristine pinned tree that
# build.sh git-reverts afterwards. The ksunext integration runs after this.
#
# Strict by design: `git apply --check` for the WHOLE series first, so a drifted
# tree fails before anything is touched, then `git apply` (no fuzz) one by one.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
SERIES="${SERIES:-$PROJ/patches/series}"
say(){ echo "  [mods] $*"; }
die(){ echo "✗ [mods] $*" >&2; exit 1; }

[[ -f "$SERIES" ]] || die "no $SERIES"
mapfile -t PATCHES < <(awk '!/^[[:space:]]*(#|$)/{print $1}' "$SERIES")
[[ ${#PATCHES[@]} -gt 0 ]] || die "$SERIES lists no patches"

# Every patch was generated against the pinned tree; a dirty tree here means
# build.sh's pristine reset did not run, and nothing below would be trustworthy.
[[ -z "$(git -C "$KERNEL_SRC" status --porcelain)" ]] \
  || die "$KERNEL_SRC is not pristine — refusing to stack patches on unknown changes"

for p in "${PATCHES[@]}"; do
  [[ -f "$PROJ/patches/$p" ]] || die "series names $p but patches/$p does not exist"
done

# A series is checked as a unit: patch N may depend on N-1, so check them by
# applying to a scratch index rather than one-by-one against the pristine tree.
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
export GIT_INDEX_FILE="$SCRATCH/index"
git -C "$KERNEL_SRC" read-tree HEAD
for p in "${PATCHES[@]}"; do
  git -C "$KERNEL_SRC" apply --whitespace=nowarn --cached --check "$PROJ/patches/$p" 2>"$SCRATCH/err" \
    || die "$p does not apply EXACTLY to $(git -C "$KERNEL_SRC" rev-parse --short HEAD):
$(cat "$SCRATCH/err")
   The tree drifted from the one this patch was ported against — re-port it."
  git -C "$KERNEL_SRC" apply --whitespace=nowarn --cached "$PROJ/patches/$p"
done
unset GIT_INDEX_FILE

for p in "${PATCHES[@]}"; do
  git -C "$KERNEL_SRC" apply --whitespace=nowarn "$PROJ/patches/$p" || die "$p failed to apply after a clean check"
  say "applied $p"
done
say "${#PATCHES[@]} patches applied, strict (no fuzz)"
