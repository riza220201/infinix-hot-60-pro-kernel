#!/bin/bash -e
# --workspace_status_command replacement, used instead of kleaf's own for release
# builds.
#
# WHY: kleaf composes the release as
#     <version>  -<android_release>-<KMI_GENERATION>  <STABLE_SCMVERSION>  <CONFIG_LOCALVERSION>
# With --config=stamp the third field becomes "-g<sha>-dirty", giving
#     6.12.38-android16-5-g1ad7be92b3ed-dirty-RivalAbadi-ksunext-4k
# and WITHOUT --config=stamp it is the literal placeholder "-maybe-dirty"
# (impl/stamp.bzl:63). Neither is shippable. kleaf reads STABLE_SCMVERSIONS as a
# JSON map {kernel_dir: scmversion}, so emitting an empty string for our kernel dir
# drops that field entirely and leaves CONFIG_LOCALVERSION to carry the brand:
#     6.12.38-android16-5-RivalAbadi-ksunext-4k
#
# ⚠ TRADE-OFF: the built kernel then no longer self-reports its source commit. That
#   is acceptable HERE only because sources.lock pins it, build.sh refuses to build
#   off a drifted tree, and the gate logs record the exact ref — provenance lives in
#   the repo instead of in `uname -r`. Do not copy this into a workflow that lacks
#   those three things.
#
# Everything else kleaf emits (SOURCE_DATE_EPOCHS, etc.) is passed through unchanged.
# kleaf's own copy of this script lives four levels inside the kernel workspace and
# derives the root with four dirnames. Ours lives in $PROJ/tools, so that arithmetic
# lands somewhere else entirely (it resolved to /mnt/Data and died with status 127).
# Derive it from THIS script's location instead: <proj>/tools/x.sh -> <proj>/.build/kernel.
SELF_DIR=$(dirname "$(readlink -f "$0")")
PROJ_DIR=$(dirname "$SELF_DIR")
KLEAF_REPO_DIR="${KLEAF_WORKSPACE:-$PROJ_DIR/.build/kernel}"
[[ -f "$KLEAF_REPO_DIR/build/kernel/kleaf/workspace_status_common.sh" ]] || {
  echo "workspace-status-clean.sh: kleaf not found under $KLEAF_REPO_DIR" >&2; exit 1; }

"${KLEAF_REPO_DIR}/build/kernel/kleaf/workspace_status_common.sh"
"${KLEAF_REPO_DIR}/prebuilts/build-tools/path/linux-x86/python3" \
  "${KLEAF_REPO_DIR}/build/kernel/kleaf/workspace_status_stamp.py" \
  | grep -v '^STABLE_SCMVERSIONS '
echo 'STABLE_SCMVERSIONS {"common": ""}'
