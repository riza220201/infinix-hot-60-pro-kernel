#!/usr/bin/env bash
# Report the toolchain fetch's real state — including "the writer is dead".
#
#   tools/fetch-status.sh        -> one verdict line, exit 0 done / 1 not done
#
# 🪤 Why this exists. The status marker alone is not enough: a run killed
# mid-flight leaves its last line saying RUNNING forever. On 2026-09-29 that read
# "RUNNING since 20:38" seventeen hours after the process had died. So this reads
# the HEARTBEAT and calls a stale one what it is, and then checks the filesystem —
# which is the only authority on whether the fetch actually achieved anything.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${KERNEL_WS:-$PROJ/.build/kernel}"
STATUS="$PROJ/.build/fetch-status"
STALE_AFTER=180   # seconds; the heartbeat beats every 30

NEEDED=(common build/kernel tools/mkbootimg
        prebuilts/clang/host/linux-x86 prebuilts/rust prebuilts/build-tools
        prebuilts/kernel-build-tools prebuilts/ndk-r26)
missing=(); for d in "${NEEDED[@]}"; do [[ -e "$WS/$d" ]] || missing+=("$d"); done

line="$(cat "$STATUS" 2>/dev/null | head -1)"
verdict="UNKNOWN"
case "$line" in
  DONE*)    verdict="DONE" ;;
  FAILED*)  verdict="FAILED" ;;
  PAUSED*)  verdict="PAUSED" ;;
  INTERRUPTED*) verdict="INTERRUPTED (killed mid-flight; re-run to resume)" ;;
  RUNNING*)
    hb="$(sed -n 's/.*heartbeat \([^ ]*\).*/\1/p' <<<"$line")"
    if [[ -n "$hb" ]]; then
      age=$(( $(date +%s) - $(date -d "$hb" +%s 2>/dev/null || echo 0) ))
      if (( age > STALE_AFTER )); then
        verdict="DEAD (heartbeat ${age}s stale — the writer is gone)"
      else
        verdict="RUNNING (heartbeat ${age}s ago)"
      fi
    else
      verdict="RUNNING? (no heartbeat in the marker — an old-format run)"
    fi ;;
  '')       verdict="NEVER RUN (no marker)" ;;
esac

echo "verdict : $verdict"
echo "marker  : ${line:-<none>}"
# The filesystem is the authority. A marker can lie; a missing directory cannot.
if (( ${#missing[@]} == 0 )); then
  echo "projects: all 8 present — toolchain COMPLETE"
  echo "next    : ./build.sh vanilla --stock"
  exit 0
fi
echo "projects: ${#missing[@]} missing — ${missing[*]}"
echo "next    : setsid nohup ./tools/fetch-toolchain.sh > /dev/null 2>&1 < /dev/null &"
exit 1
