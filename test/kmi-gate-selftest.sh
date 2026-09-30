#!/usr/bin/env bash
# Prove the KMI gate can FAIL. A gate that only ever passes is not a gate.
#
# Runs before any kernel of ours exists, by feeding kmi_check.py the symvers
# HARVESTED from the device's own shipped modules as a stand-in for a built
# kernel: a perfect kernel, by construction. Then each negative control breaks
# exactly one thing and asserts the gate says so — and says WHICH kind of wrong
# it is, because "bad kernel" and "wrong reference set" are different problems
# with different fixes.
#
# Usage: test/kmi-gate-selftest.sh [foreign_module.ko]
#   foreign_module.ko — any .ko from a DIFFERENT device, for negative D.
#                       Skipped (not failed) if not supplied or not found.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ"
source ./device.conf 2>/dev/null || true

REF="${KMI_REF_TREE:-$PROJ/.build/kmi-ref}"
SYMVERS="$REF/stock-derived.symvers"
FOREIGN="${1:-}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

run() { # run <name> <expected-exit> <symvers> <reftree> [env...]
  local name="$1" want="$2" sv="$3" rt="$4"; shift 4
  local out rc
  out="$(env "$@" python3 lib/kmi_check.py "$sv" "$rt" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then
    printf '  ✅ %-52s exit %s\n' "$name" "$rc"; pass=$((pass+1))
  else
    printf '  ❌ %-52s exit %s (wanted %s)\n' "$name" "$rc" "$want"; fail=$((fail+1))
    echo "$out" | sed 's/^/       /'
  fi
  LAST_OUT="$out"
}

[[ -f "$SYMVERS" ]] || { echo "no $SYMVERS — run tools/harvest-kmi-ref.py first"; exit 2; }

echo "KMI gate self-test  (reference: $REF)"
echo

echo "POSITIVE controls"
run "device-derived symvers vs the real reference set" 0 "$SYMVERS" "$REF" \
    KMI_EXPECT_VERMAGIC="${KMI_EXPECT_VERMAGIC:-}" \
    KMI_VERMAGIC_EXCEPTIONS="${KMI_VERMAGIC_EXCEPTIONS:-}"
grep -q "CRC-MISMATCH  : 0" <<<"$LAST_OUT" \
  && { echo "     …and it is a perfect score, not merely exit 0"; pass=$((pass+1)); } \
  || { echo "     ❌ exit 0 but NOT a perfect score"; fail=$((fail+1)); }

echo
echo "NEGATIVE controls"

# A — one ordinary symbol's CRC perturbed: ordinary CRC failure.
awk -F'\t' 'BEGIN{OFS="\t"} $2=="memset"{$1="0xdeadbeef"} {print}' "$SYMVERS" > "$TMP/a.symvers"
run "A: one ordinary CRC (memset) perturbed" 1 "$TMP/a.symvers" "$REF"

# B — module_layout itself perturbed: every module rejected.
awk -F'\t' 'BEGIN{OFS="\t"} $2=="module_layout"{$1="0xdeadbeef"} {print}' "$SYMVERS" > "$TMP/b.symvers"
run "B: module_layout perturbed" 1 "$TMP/b.symvers" "$REF"
grep -qE "module_layout   : ok=0 bad=424" <<<"$LAST_OUT" \
  && { echo "     …and it names all 424 modules, not a CRC footnote"; pass=$((pass+1)); } \
  || { echo "     ❌ did not report ok=0 bad=424"; fail=$((fail+1)); }

# C — empty reference tree: must refuse to call nothing a pass.
mkdir -p "$TMP/empty"
run "C: empty reference tree (vacuous-pass guard)" 2 "$SYMVERS" "$TMP/empty"

# D — wrong reference set, provoked by changing the EXPECTATION, not by keeping a
#     contaminated set on disk. Identical code path, no bad artefact to store.
run "D: expectation names a different vermagic" 3 "$SYMVERS" "$REF" \
    KMI_EXPECT_VERMAGIC="6.12.99-android16-9-gdeadbeef-4k"

# E — a genuinely FOREIGN module dropped into the reference set. This is the one
#     that matters: it must say "wrong reference set", not drown in CRC noise.
if [[ -n "$FOREIGN" && -f "$FOREIGN" ]]; then
  cp -r "$REF" "$TMP/ref"; rm -f "$TMP/ref"/*.symvers
  cp "$FOREIGN" "$TMP/ref/vendor_dlkm/zz-foreign.ko"
  run "E: foreign .ko in the reference set" 3 "$SYMVERS" "$TMP/ref" \
      KMI_EXPECT_VERMAGIC="${KMI_EXPECT_VERMAGIC:-}"
  grep -q "vendor_dlkm/zz-foreign.ko" <<<"$LAST_OUT" \
    && { echo "     …and it names the stray by its tree path"; pass=$((pass+1)); } \
    || { echo "     ❌ did not name the stray by tree path"; fail=$((fail+1)); }
else
  echo "  ⏭  E: foreign .ko — skipped (no foreign module supplied)"
fi

# F — the exception list excuses the PROVENANCE layer and nothing else. Declaring
#     the stray must move the verdict from 3 (wrong reference set) to 1 (bad
#     CRCs) — NOT to 0. The two layers have to stay independent, or an entry in
#     KMI_VERMAGIC_EXCEPTIONS would quietly buy a module a pass on the ABI too.
if [[ -n "$FOREIGN" && -f "$FOREIGN" ]]; then
  run "F: declared exception excuses provenance ONLY" 1 "$SYMVERS" "$TMP/ref" \
      KMI_EXPECT_VERMAGIC="${KMI_EXPECT_VERMAGIC:-}" \
      KMI_VERMAGIC_EXCEPTIONS="zz-foreign.ko"
  if grep -q "^provenance      : ok" <<<"$LAST_OUT" \
     && grep -q "declared exception(s): zz-foreign.ko" <<<"$LAST_OUT"; then
    echo "     …provenance passed, CRC layer still failed it independently"; pass=$((pass+1))
  else
    echo "     ❌ the exception did not take effect on the provenance layer"; fail=$((fail+1))
  fi
  echo "     (the exception is a HOLE in the provenance layer, on purpose — give"
  echo "      every device.conf entry a reason, because nothing else will ask)"
fi

echo
echo "passed $pass, failed $fail"
[[ "$fail" == 0 ]]
