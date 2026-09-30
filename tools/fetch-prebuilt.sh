#!/usr/bin/env bash
# fetch-prebuilt.sh — fetch ONE prebuilt toolchain version, subdirectory by
# subdirectory, via gitiles `+archive`.
#
#   tools/fetch-prebuilt.sh <repo-path> <ref> <subtree> <dest-dir>
#
# e.g. tools/fetch-prebuilt.sh platform/prebuilts/clang/host/linux-x86 \
#          refs/heads/main-kernel-2025 clang-r536225 \
#          .build/kernel/prebuilts/clang/host/linux-x86/clang-r536225
#
# 🔴 WHY NOT `repo sync`, WHICH IS THE OBVIOUS ANSWER
# `prebuilts/clang/host/linux-x86` holds EVERY clang version (r536225, r547379,
# clang-stable, mlgo-models, profiles…) and `prebuilts/rust` holds four rust
# toolchains. We need exactly one of each. Syncing them pulled 7 GB and 22 GB
# respectively and still was not finished — to use maybe 3 GB of it.
#
# 🔴 AND WHY NOT A PLAIN PARTIAL CLONE, THE OTHER OBVIOUS ANSWER
# `--filter=blob:none` + sparse-checkout fetches the right FILES, but it fetches
# them as thousands of individual blobs: measured at 0.15 MiB/s on this link
# against ~1 MiB/s for a bulk archive. And an interrupted blob batch is written
# as `size-garbage`, which git will not reuse — so it is not resumable either.
#
# ⭐ WHAT THIS DOES INSTEAD. gitiles serves any subtree as one gzip stream, so we
# fetch per top-level subdirectory. Each subdirectory that lands is a CHECKPOINT
# that survives an interruption — which matters more than raw speed on a link
# that has already dropped multi-GB transfers repeatedly today.
# ⚠ `+archive` answers Range requests with 200, not 206, so a single stream is
# NOT resumable. The subdirectory split IS the resumability.
set -uo pipefail

REPO="${1:?repo path, e.g. platform/prebuilts/clang/host/linux-x86}"
REF="${2:?ref, e.g. refs/heads/main-kernel-2025}"
SUBTREE="${3:?subtree, e.g. clang-r536225}"
DEST="${4:?destination directory}"
BASE="https://android.googlesource.com/$REPO/+archive/$REF/$SUBTREE"
STATE="$DEST/.fetched"

mkdir -p "$DEST"; touch "$STATE"
say() { echo "  $*"; }

# The entry list comes from a blobless metadata clone if one is supplied,
# otherwise from a probe of the usual names.
if [[ -n "${ENTRIES:-}" ]]; then
  read -ra LIST <<<"$ENTRIES"
else
  echo "set ENTRIES='a b c' to the subtree's top-level entries" >&2; exit 2
fi

echo "== $SUBTREE -> $DEST"
echo "   ${#LIST[@]} entries, each fetched and extracted independently"
done_n=0; skip_n=0; fail_n=0
for e in "${LIST[@]}"; do
  if grep -qxF "$e" "$STATE"; then
    say "· $e already done"; skip_n=$((skip_n+1)); continue
  fi
  ok=0
  for try in 1 2 3; do
    tmp="$DEST/.tmp-$e.tar.gz"
    # --fail so a 400/404 (an entry that is a plain file, or absent) is visible
    if curl -sSfL --max-time 3600 --speed-limit 1024 --speed-time 300 \
            -o "$tmp" "$BASE/$e.tar.gz" 2>/dev/null; then
      mkdir -p "$DEST/$e"
      if tar -xzf "$tmp" -C "$DEST/$e" 2>/dev/null; then
        rm -f "$tmp"; echo "$e" >> "$STATE"
        say "✓ $e  ($(du -sh "$DEST/$e" | cut -f1))"; ok=1; break
      fi
    fi
    rm -f "$tmp"
    # not a directory? fetch it as a single file from the raw endpoint instead
    if [[ $try -eq 1 ]]; then
      if curl -sSfL --max-time 300 -o "$DEST/$e" \
           "https://android.googlesource.com/$REPO/+/$REF/$SUBTREE/$e?format=TEXT" 2>/dev/null; then
        base64 -d < "$DEST/$e" > "$DEST/$e.dec" 2>/dev/null && mv "$DEST/$e.dec" "$DEST/$e"
        echo "$e" >> "$STATE"; say "✓ $e  (single file)"; ok=1; break
      fi
      rm -f "$DEST/$e"
    fi
    # 🪤 An entry can be a directory holding only SYMLINKS. gitiles' archive of
    #    such a tree extracts to nothing useful and the fetch looks like a
    #    failure — rust's `src/` is exactly this: one link, stdlibs ->
    #    ../lib/rustlib/src/rust, while the real sources live under lib/.
    #    Treat "archive fetched but extracted empty" as done, not failed.
    if [[ -d "$DEST/$e" ]] && [[ -z "$(ls -A "$DEST/$e" 2>/dev/null)" ]] && [[ $try -ge 2 ]]; then
      echo "$e" >> "$STATE"; say "✓ $e  (empty/symlink-only — nothing to extract)"; ok=1; break
    fi
    say "… $e attempt $try failed, retrying"
  done
  [[ $ok -eq 1 ]] && done_n=$((done_n+1)) || { say "✗ $e FAILED after 3 tries"; fail_n=$((fail_n+1)); }
done

echo "   fetched $done_n · already had $skip_n · failed $fail_n"
[[ $fail_n -eq 0 ]]
