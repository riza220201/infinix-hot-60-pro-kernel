#!/usr/bin/env bash
# Create the v2 GitHub release (as a DRAFT) + upload all assets via the GitHub REST
# API — no `gh` needed, reuses a classic PAT with `repo` scope (or `gh auth token`).
# Review the draft on GitHub, then hit Publish.
#
#   GH_TOKEN=<your-classic-PAT> bash release-v2.sh
#   GH_TOKEN=$(gh auth token)   bash release-v2.sh
#
# Same shape as itel-rs4-kernel's release-v7.sh. Refuses to run unless the remote tag
# v2 is the local tag v2, so the release can never attach to a different commit than
# the one the assets were built from. Refuses if a v2 release already exists.
# Release body = RELEASE-NOTES.md (the tracked notes ARE the release page).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="riza220201/infinix-hot-60-pro-kernel"
TAG="v2"
TITLE="Rival Abadi Kernel v2 — Infinix HOT 60 Pro+ (MT6789 · android16-6.12)"
NOTES="RELEASE-NOTES.md"
DATE="20261001"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>, or GH_TOKEN=\$(gh auth token)}"
ASSETS=(
  out/vanilla/InfinixHOT60Pro-vanilla-$DATE.zip
  out/vanilla/InfinixHOT60Pro-boot-vanilla-$DATE.img
  out/ksunext/InfinixHOT60Pro-ksunext-$DATE.zip
  out/ksunext/InfinixHOT60Pro-boot-ksunext-$DATE.img
)
for f in "$NOTES" "${ASSETS[@]}"; do [[ -f "$f" ]] || { echo "✗ missing: $f"; exit 1; }; done

local_tag=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
remote_tag=$(git ls-remote origin "refs/tags/$TAG^{}" "refs/tags/$TAG" | awk 'NR==1{print $1}')
remote_peeled=$(git ls-remote origin "refs/tags/$TAG^{}" | awk '{print $1}')
[[ -n "$remote_peeled" ]] && remote_tag="$remote_peeled"
[[ -n "$local_tag" && "$local_tag" == "$remote_tag" ]] \
  || { echo "✗ tag $TAG: local ${local_tag:-none} != remote ${remote_tag:-none} — push the tag first"; exit 1; }
echo "✓ tag $TAG -> ${local_tag:0:12} on both sides"

# The checksums in the notes must be the checksums of the files being uploaded.
for f in "${ASSETS[@]}"; do
  h=$(sha256sum "$f" | cut -d' ' -f1)
  grep -q "$h  $(basename "$f")" "$NOTES" \
    || { echo "✗ $NOTES does not list $(basename "$f") as $h — rebuilt since the notes were written?"; exit 1; }
done
echo "✓ every asset's sha256 matches the Checksums section of $NOTES"

api() { curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
if api "https://api.github.com/repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1; then
  echo "✗ a published release for $TAG already exists — refusing to create another"; exit 1
fi
if api "https://api.github.com/repos/$REPO/releases?per_page=100" \
   | python3 -c 'import json,sys; sys.exit(0 if any(r.get("tag_name")==sys.argv[1] for r in json.load(sys.stdin)) else 1)' "$TAG"; then
  echo "✗ a (draft) release for $TAG already exists — delete it on GitHub first"; exit 1
fi

# SHA256SUMS over exactly the assets being published
( cd out && sha256sum "${ASSETS[@]#out/}" ) > out/SHA256SUMS
ASSETS+=(out/SHA256SUMS)
cat out/SHA256SUMS

# 1) create the release (draft)
payload=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[2],"body":open(sys.argv[3]).read(),"draft":True}))' "$TAG" "$TITLE" "$NOTES")
resp=$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$payload")
rel_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$resp")
echo "✓ draft release created (id=$rel_id)"

# 2) upload each asset
for f in "${ASSETS[@]}"; do
  name=$(basename "$f")
  ct="application/octet-stream"; [[ "$f" == *.zip ]] && ct="application/zip"
  [[ "$f" == *SHA256SUMS ]] && ct="text/plain"
  echo "  ↑ $name"
  curl -fsS -X POST "https://uploads.github.com/repos/$REPO/releases/$rel_id/assets?name=$name" \
    -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: $ct" \
    --data-binary @"$f" >/dev/null
done
echo "✓ all assets uploaded — review + Publish the DRAFT at:"
echo "  https://github.com/$REPO/releases"
