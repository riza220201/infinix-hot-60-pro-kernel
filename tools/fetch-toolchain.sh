#!/usr/bin/env bash
# Fetch/resume the GKI kleaf workspace, and leave a MARKER saying how it ended.
#
#   tools/fetch-toolchain.sh          # run it (detached is fine)
#   cat .build/fetch-status           # RUNNING | DONE | FAILED <reason>
#
# 🪤 WHY A MARKER FILE AND NOT `pgrep`.
# Three times in this project a progress check answered about ITSELF:
#   1. `pgrep -f "repo sync"` matched the shell whose command line contained that
#      string -> reported RUNNING forever, including after a reboot.
#   2. The `repo[ ]sync` bracket fixed the pattern, but a later watcher script
#      also contained `echo "=== repo sync exited ..."` — so pgrep matched the
#      WATCHER's own command line again. The sync had failed 71 minutes earlier
#      and the watcher could never fire.
#   3. `git apply --check ... | tail; echo $?` reported tail's status, not git's.
# A marker file has no such failure mode: it is written by the thing being
# watched, it says what happened, and it cannot describe the observer.
#
# Also note what is NOT passed: `--fail-fast`. A single TLS blip on one project
# was killing the whole run and discarding every other project's in-flight pack
# (14.8 GB lost that way on 2026-09-29). Without it, a failing project is retried
# and the others keep their progress.
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${KERNEL_WS:-$PROJ/.build/kernel}"
STATUS="$PROJ/.build/fetch-status"
LOG="$PROJ/.build/fetch-$(date +%Y%m%d-%H%M%S).log"

MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
MANIFEST_BRANCH="common-android16-6.12-lts"
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock" && \
  MANIFEST_URL="${KERNEL_MANIFEST_URL:-$MANIFEST_URL}" && \
  MANIFEST_BRANCH="${KERNEL_MANIFEST_BRANCH:-$MANIFEST_BRANCH}"

# The eight projects the kleaf build actually needs.
NEEDED=(common build/kernel tools/mkbootimg
        prebuilts/clang/host/linux-x86 prebuilts/rust prebuilts/build-tools
        prebuilts/kernel-build-tools prebuilts/ndk-r26)

missing() { local m=(); for d in "${NEEDED[@]}"; do [[ -e "$WS/$d" ]] || m+=("$d"); done; echo "${m[@]}"; }

# 🪤 `repo sync` TRACKS THE BRANCH, so it fast-forwards `common` past our pin —
# silently, because the tree stays clean. On 2026-09-29 it moved us one commit
# from 57041e4a to 4ae46dd3, which restructured fs/proc/task_mmu.c by 579 lines
# and turned a SusFS patch that applied with ZERO failures into one with two
# failing hunks. The lockfile was right; nothing was enforcing it.
# 🔑 A pin that is only recorded is a note. A pin that is re-asserted is a pin.
repin() {
  [[ -n "${KERNEL_COMMON_REF:-}" ]] || return 0
  [[ -d "$WS/common/.git" ]] || return 0
  local cur; cur="$(git -C "$WS/common" rev-parse HEAD 2>/dev/null)"
  [[ "$cur" == "$KERNEL_COMMON_REF" ]] && return 0
  echo "== common drifted ${cur:0:9} -> re-pinning to ${KERNEL_COMMON_REF:0:9}" | tee -a "$LOG"
  git -C "$WS/common" fetch --depth 1 aosp "$KERNEL_COMMON_REF" >>"$LOG" 2>&1 || true
  git -C "$WS/common" checkout -q "$KERNEL_COMMON_REF" >>"$LOG" 2>&1 \
    || echo "   WARNING: could not restore the pin" | tee -a "$LOG"
}

mkdir -p "$WS" "$PROJ/.build"

# 🪤 curl 28: "Operation too slow. Less than 1000 bytes/sec transferred the last
# 60 seconds". That is not a disconnect — it is GIT'S OWN default abort
# (http.lowSpeedLimit=1000, http.lowSpeedTime=60) firing on a link that pauses.
# On 2026-09-30 it killed the clang fetch twice at ~7 GB, and since a failed pass
# discards its tmp_pack, each attempt threw away 7 GB and started over.
# A slow link is not an error; only a dead one is. Let it stall and keep waiting.
export GIT_HTTP_LOW_SPEED_LIMIT=0
export GIT_HTTP_LOW_SPEED_TIME=0


# 🔴 SINGLE INSTANCE. On 2026-09-30 a kill that silently matched nothing left the
# first run alive while a second was launched, and TWO `repo sync` processes ran
# against the same `.repo` for a minute. Nothing was corrupted, but only by luck.
# flock is the fix: the second invocation refuses instead of competing.
LOCK="$PROJ/.build/fetch.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another fetch already holds $LOCK — refusing to start a second one." >&2
  echo "  state: $("$PROJ/tools/fetch-status.sh" 2>/dev/null | head -1)" >&2
  exit 1
fi


# 🪤 A marker written ONLY at transitions cannot distinguish "running" from
# "killed". On 2026-09-29 this script was killed seconds after launch (terminal
# closed) and the marker still read "RUNNING since 20:38" seventeen hours later —
# indistinguishable, to a reader, from healthy progress.
# 🔑 Liveness needs a HEARTBEAT, not a state word. The reader compares the
# heartbeat to now; a stale heartbeat means the writer is gone, whatever the
# state word says.
STARTED="$(date -Iseconds)"
beat() { printf 'RUNNING since %s  heartbeat %s  pid %s\n' "$STARTED" "$(date -Iseconds)" "$$" > "$STATUS"; }
beat
( while :; do sleep 30; beat; done ) &
HEARTBEAT_PID=$!
# Any exit path stops the heartbeat, so it can never outlive the work and report
# a corpse as healthy.
# ⚠ EXIT alone is not enough: bash does NOT run an EXIT trap for an untrapped
# SIGTERM, so `kill <script>` orphaned the heartbeat, which then kept writing
# "RUNNING" over a later run's marker. Trap the signals that actually arrive.
cleanup() {
  local rc=$?
  kill "$HEARTBEAT_PID" 2>/dev/null
  # Don't leave a stale RUNNING behind if we were killed mid-flight.
  if [[ $rc -ne 0 ]] && grep -q '^RUNNING' "$STATUS" 2>/dev/null; then
    echo "INTERRUPTED $(date -Iseconds) — stopped before finishing; re-run to resume" > "$STATUS"
  fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Re-assert the pin BEFORE the first pass as well as after each one: a run killed
# mid-pass leaves `common` fast-forwarded off the pin with a clean tree, and the
# after-pass repin never got to run.
repin

if [[ ! -d "$WS/.repo" ]]; then
  echo "== repo init" | tee -a "$LOG"
  ( cd "$WS" && repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 ) >>"$LOG" 2>&1 || {
    echo "FAILED repo init — see $LOG" > "$STATUS"; exit 1; }
fi

# Up to 4 passes. repo keeps completed projects, so each pass only redoes what
# is still missing — and a TLS failure costs one project's in-flight pack, not
# every project's.
for pass in 1 2 3 4; do
  left_list="$(missing)"
  if [[ -z "$left_list" ]]; then
    repin
    echo "DONE $(date -Iseconds) — nothing was missing" > "$STATUS"
    exit 0
  fi
  echo "== pass $pass  (fetching only: $left_list)" | tee -a "$LOG"
  # Sync ONLY the projects that are actually missing. Two reasons, both learned
  # the hard way:
  #  * `repo sync` with no arguments re-syncs `common` too, and since it tracks
  #    the manifest BRANCH it fast-forwards it off our pin every single pass —
  #    a treadmill the after-pass repin was left to undo. Not asking is better
  #    than asking and then correcting.
  #  * it also re-walks ~30 already-complete projects for nothing.
  # shellcheck disable=SC2086
  ( cd "$WS" && repo sync -c --no-tags --optimized-fetch --retry-fetches=3 -j3 $left_list ) >>"$LOG" 2>&1
  rc=$?
  left="$(missing)"
  if [[ -z "$left" ]]; then
    repin
    echo "DONE $(date -Iseconds) after $pass pass(es)" > "$STATUS"
    echo "== complete" | tee -a "$LOG"
    exit 0
  fi
  repin
  echo "   pass $pass ended rc=$rc, still missing: $left" | tee -a "$LOG"
  # Drop this pass's abandoned temp packs so they don't accumulate (14.8 GB did).
  find "$WS/.repo" -name 'tmp_pack_*' -delete 2>/dev/null
done

echo "FAILED after 4 passes — still missing: $(missing) — see $LOG" > "$STATUS"
exit 1
