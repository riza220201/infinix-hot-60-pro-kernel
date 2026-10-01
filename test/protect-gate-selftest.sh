#!/usr/bin/env bash
# Prove layer 2 of the gate — protected exports — can FAIL.
#
# Layers 1 and 3 judge what the stock modules IMPORT. Neither looks at what they
# EXPORT, and that is where v1 and v2 broke Wi-Fi: the phone's Google-signed
# rfkill.ko / libarc4.ko are unsigned to any kernel we build, and with
# CONFIG_MODULE_SIG_PROTECT an unsigned module exporting a protected symbol is
# refused (-EACCES) — cfg80211, mac80211 and the Wi-Fi driver go down with it.
# Layers 1 and 3 called those kernels CLEAN.
#
# Synthetic list/symvers inputs against the real reference tree, so no kernel
# build is needed. NEG K is the exact shape of the v1/v2 Wi-Fi failure.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ"
source ./device.conf 2>/dev/null || true

REF="${KMI_REF_TREE:-$PROJ/.build/kmi-ref}"
GATE=(python3 "$PROJ/lib/protect_check.py" -)   # "-": synthetic inputs, no vmlinux
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
says() { # says <description> <pattern> — assert on the last run's output
  if grep -q -- "$2" <<<"$LAST_OUT"; then
    echo "     …$1"; pass=$((pass+1))
  else
    echo "     ❌ $1 — not in the output"; fail=$((fail+1))
  fi
}

[[ -f "$REF/vendor_dlkm/rfkill.ko" ]] || { echo "no $REF/vendor_dlkm/rfkill.ko — run tools/extract-device-material.sh first"; exit 2; }

printf '0x0\trfkill_alloc\tnet/rfkill/rfkill\tEXPORT_SYMBOL_GPL\t\n0x0\tarc4_crypt\tlib/crypto/libarc4\tEXPORT_SYMBOL\t\n0x0\thci_register_dev\tnet/bluetooth/bluetooth\tEXPORT_SYMBOL_GPL\t\n' > "$TMP/Module.symvers"
printf 'net/bluetooth/bluetooth\n'                                     > "$TMP/list-ok"
printf 'net/bluetooth/bluetooth\nnet/rfkill/rfkill\nlib/crypto/libarc4\n' > "$TMP/list-v2"
printf 'net/nosuch/module\n'                                           > "$TMP/list-orphan"
mkdir -p "$TMP/empty"

echo "protected-exports gate self-test  (reference: $REF)"
echo "POSITIVE control"
run "rfkill + libarc4 unprotected (the fix)"           0 "${GATE[@]}" "$TMP/Module.symvers" "$TMP/list-ok" "$REF"
says "and it says CLEAN"                                "RESULT: CLEAN"
echo "NEGATIVE controls"
run "K: rfkill + libarc4 protected (v1/v2 Wi-Fi bug)"  1 "${GATE[@]}" "$TMP/Module.symvers" "$TMP/list-v2" "$REF"
says "names vendor_dlkm/rfkill.ko"                      "REFUSED       : vendor_dlkm/rfkill.ko"
says "names vendor_dlkm/libarc4.ko"                     "REFUSED       : vendor_dlkm/libarc4.ko"
run "L: protected-modules list missing"                 2 "${GATE[@]}" "$TMP/Module.symvers" "$TMP/no-such-list" "$REF"
run "M: empty reference tree"                           2 "${GATE[@]}" "$TMP/Module.symvers" "$TMP/list-v2" "$TMP/empty"
run "N: list names modules symvers knows nothing of"   2 "${GATE[@]}" "$TMP/Module.symvers" "$TMP/list-orphan" "$REF"
says "and calls it VACUOUS, not a pass"                 "NOT a pass"

echo
echo "passed $pass, failed $fail"
[[ "$fail" == 0 ]]
