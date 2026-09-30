#!/usr/bin/env bash
# Prove layer 3 of the gate — import accounting — can FAIL.
#
# The CRC gate (test/kmi-gate-selftest.sh) answers "do the numbers agree". It is
# blind to two failures that put the phone in exactly the same state:
#   * a symbol the kernel no longer exports at all      -> "Unknown symbol"
#   * a symbol exported with a correct CRC that the module is not PERMITTED to
#     import -> -EACCES in resolve_symbol(), which is what a kernel built with
#     too narrow a symbol list produces. The CRC gate calls that kernel CLEAN.
#
# Both are exercised here, against the device-derived reference, before any
# kernel of ours exists.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ"
source ./device.conf 2>/dev/null || true

REF="${KMI_REF_TREE:-$PROJ/.build/kmi-ref}"
DERIVED="$REF/stock-derived.symvers"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

run() { # run <name> <expected-exit> <args...>
  local name="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then
    printf '  ✅ %-54s exit %s\n' "$name" "$rc"; pass=$((pass+1))
  else
    printf '  ❌ %-54s exit %s (wanted %s)\n' "$name" "$rc" "$want"; fail=$((fail+1))
    echo "$out" | sed 's/^/       /'
  fi
  LAST_OUT="$out"
}
says() { # says <description>  — assert on the last run's output
  if grep -q -- "$2" <<<"$LAST_OUT"; then
    echo "     …$1"; pass=$((pass+1))
  else
    echo "     ❌ $1 — not in the output"; fail=$((fail+1))
  fi
}

[[ -f "$DERIVED" ]] || { echo "no $DERIVED — run tools/extract-device-material.sh first"; exit 2; }

echo "import gate self-test  (reference: $REF)"
echo
echo "building the control: the symvers a REAL kernel would have"
python3 tools/vmlinux-only-symvers.py "$DERIVED" "$REF" "$TMP/vmlinux.symvers" | sed 's/^/  /'
mkdir -p "$TMP/empty"

echo
echo "POSITIVE control"
run "realistic kernel: every import accounted for" 0 \
    python3 lib/import_check.py "$TMP/vmlinux.symvers" "$REF"
says "0 unresolved, and the three buckets sum to the whole import set" "UNRESOLVED    : 0"

echo
echo "NEGATIVE controls"

# G — the kernel stops exporting one symbol. Invisible to the CRC layer, which
#     only compares symbols it FINDS.
VICTIM="$(head -1 "$TMP/vmlinux.symvers" | cut -f2)"
grep -v "	${VICTIM}	" "$TMP/vmlinux.symvers" > "$TMP/g.symvers"
run "G: kernel stopped exporting '$VICTIM'" 1 \
    python3 lib/import_check.py "$TMP/g.symvers" "$REF"
says "named as a SURPRISE, with the modules that want it" "SURPRISE: $VICTIM"

# H — the same absence, declared. A known pre-existing stock defect has to be
#     sayable once, in one place, instead of remembered.
run "H: that absence declared in KMI_UNRESOLVED_EXPECTED" 0 \
    env KMI_UNRESOLVED_EXPECTED="$VICTIM" \
    python3 lib/import_check.py "$TMP/g.symvers" "$REF"

# I — present, correct CRC, but not permitted to import.
cut -f2 "$TMP/vmlinux.symvers" | head -50 > "$TMP/narrow.symbollist"
run "I: correct CRCs, too-narrow permitted list" 1 \
    python3 lib/import_check.py "$TMP/vmlinux.symvers" "$REF" "$TMP/narrow.symbollist"
says "reported as -EACCES at resolve_symbol(), not as a CRC fault" "\-EACCES:"

# J — vacuous-pass guard, same rule as layer 1: nothing checked is not a pass.
run "J: empty reference tree" 2 \
    python3 lib/import_check.py "$TMP/vmlinux.symvers" "$TMP/empty"

echo
echo "passed $pass, failed $fail"
[[ "$fail" == 0 ]]
