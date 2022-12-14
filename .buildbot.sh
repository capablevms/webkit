#!/bin/bash
#
# Copyright (C) 2022 Arm Ltd.
# SPDX-License-Identifier: MIT OR Apache-2.0

set -eu

# Buildbot respects ANSI colours.
C_BOLD="\033[1m"
C_RESET="\033[m"

timestamp() {
  local DELTA=''
  if [ -n "${TIMESTAMP:-}" ]; then
    local NEW_TIMESTAMP="$(date +%s)"
    local TOTAL_S="$(( $NEW_TIMESTAMP - $TIMESTAMP ))"
    # Show time taken for long-running commands (>1m).
    local S="$(( TOTAL_S % 60 ))s"
    if (( $TOTAL_S >= 60 )); then
      local M="$(( (TOTAL_S / 60) % 60 ))m"
      if (( $TOTAL_S >= 3600 )); then
        local H="$(( TOTAL_S / 3600 ))h"
      fi
      DELTA=" (took ${H-}${M-}$S)"
    fi
    TIMESTAMP="$NEW_TIMESTAMP"
  else
    TIMESTAMP="$(date +%s)"
  fi
  echo -e "$C_BOLD$(date --date="@$TIMESTAMP" "+%H:%M:%S$DELTA")$C_RESET: $@"
}
timestamp "Entered $0."

# Standard buildbot variables.
CHERI_DIR="${CHERI_DIR-$HOME/cheri/output}"
CHERIBUILD_DIR="${CHERIBUILD_DIR-$HOME/cheri-build}"
WEBKIT_DIR="${REPO_DIR-$PWD}"
cd "$WEBKIT_DIR"

CHERI_RO_DIR="$(dirname "$CHERI_DIR")"  # E.g. ~/cheri

BUILDBOT_SCRATCH_DIR=$(mktemp -d --tmpdir -t .buildbot-scratch-XXXXXX)
timestamp "Using temporary directory: $BUILDBOT_SCRATCH_DIR"
cleanup() {
  timestamp "Cleaning up: $BUILDBOT_SCRATCH_DIR"
  rm -rf "$BUILDBOT_SCRATCH_DIR"
  trap '' INT TERM EXIT
  timestamp "Done!"
  exit
}
trap cleanup INT TERM EXIT

# We need to run ./cheribuild.py, but it needs a source tree. $CHERI_RO_DIR is
# provided (with at least the SDK and filesystem images), but is read-only, so
# we need to copy it.
#
# TODO: Consider using symlinks to sub-trees that only need to be read-only.
CHERI_RW_DIR="$BUILDBOT_SCRATCH_DIR/cheri"
timestamp "Copying $CHERI_RO_DIR to $CHERI_RW_DIR..."
RULES=(
  '--include=/output/'
  '--include=/icu/'     # ICU probably isn't present, but we'll take it if it is.
  '--exclude=/*/'
  '--exclude=*.img'     # Don't copy large disk images.
  # Files in /rescue are hardlinked together and end up very large after
  # copying. -H could preserve links, but it's easier to just exclude them.
  '--exclude=**/rootfs-*/rescue/'
)
rsync -a --chmod=u+w "$CHERI_RO_DIR/" "$CHERI_RW_DIR" "${RULES[@]}"

timestamp "Symlinking WebKit test subject into the CHERI root: $CHERI_RW_DIR/webkit -> $WEBKIT_DIR"
ln -fsT "$WEBKIT_DIR" "$CHERI_RW_DIR/webkit"

# It's useful to see (roughly) what was copied in CI logs.
echo "---- $CHERI_RW_DIR ----"
ls -l "$CHERI_RW_DIR"
echo "---- $CHERI_RW_DIR/output ----"
ls -l "$CHERI_RW_DIR/output"

TARGET_FILES_DIR="$BUILDBOT_SCRATCH_DIR/target_files"
mkdir -p "$TARGET_FILES_DIR"/builds
cp -r -t "$TARGET_FILES_DIR" "PerformanceTests/SunSpider/tests/sunspider-1.0.1"
cp .buildbot-test.sh "$TARGET_FILES_DIR"/test.sh
chmod +x "$TARGET_FILES_DIR"/test.sh

build() {
  TARGET_SUFFIX="$1"
  shift

  local CHERIBUILD_ARGS=(
    "--source-root=\"$CHERI_RW_DIR\""
    '--skip-update'
  )

  case "$TARGET_SUFFIX" in
    morello-purecap)
      local FS_TYPE="morello-purecap"
      local BUILD_TYPE="morello-purecap"
      ;;
    morello-hybrid-for-purecap-rootfs)
      local FS_TYPE="morello-purecap"
      local BUILD_TYPE="morello-hybrid"
      CHERIBUILD_ARGS+=('--enable-hybrid-for-purecap-rootfs-targets')
      ;;
    *)
      echo "Unhandled TARGET_SUFFIX: $TARGET_SUFFIX"
      exit 1
      ;;
  esac

  # Flatten the build configuration to form a unique destination directory.
  local FLAT="${BUILD_TYPE}_$(echo "$*" |
                              sed "s/\(.\+\)/\L\1/g;       # Lower case
                                   s/--morello-webkit\///g;
                                   s/\s\+/_/g;
                                   s/[^a-z0-9_-]//g;")"

  pushd "$CHERIBUILD_DIR"

  # We use 'script' (below) to make cheribuild think that it has an interactive
  # shell. This isn't ideal, but cheribuild otherwise hangs with SIGTTOU on
  # consecutive calls: https://github.com/CTSRD-CHERI/cheribuild/issues/182
  # TODO: Once the cheribuild bug is fixed, remove this workaround.
  cheribuild() {
    timestamp "Building: ./cheribuild.py ${CHERIBUILD_ARGS[*]} $*"
    script -qec "./cheribuild.py ${CHERIBUILD_ARGS[*]} $*" /dev/null
  }

  cheribuild "icu4c-native"
  cheribuild "icu4c-$TARGET_SUFFIX"
  # --clean and/or --reconfigure are sometimes required when building different
  # configurations in sequence.
  cheribuild --clean --reconfigure morello-webkit-$TARGET_SUFFIX "$@"

  local FSROOT="$CHERI_RW_DIR"/output/rootfs-$FS_TYPE

  local OUTDIR="$(realpath "$TARGET_FILES_DIR"/builds)/$FLAT"
  timestamp "Build complete. Copying files to $OUTDIR..."
  mkdir "$OUTDIR"
  mkdir "$OUTDIR/bin"
  mkdir "$OUTDIR/lib"
  cp -a -t "$OUTDIR/bin" "$FSROOT"/opt/"$BUILD_TYPE"/webkit/bin/*
  cp -a -t "$OUTDIR/lib" "$FSROOT"/opt/"$BUILD_TYPE"/webkit/lib/*
  cp -a -t "$OUTDIR/lib" "$FSROOT"/usr/local/"$BUILD_TYPE"/lib/libicu*
  popd
}

build morello-purecap --morello-webkit/build-type Debug --morello-webkit/backend cloop
build morello-purecap --morello-webkit/build-type Debug --morello-webkit/backend tier1asm
# TODO: tier2asm shows intermittent failures, which are currently under
# investigation. To avoid CI disruption, it is disabled here for now, but
# should be enabled once the failures are resolved.
#build morello-purecap --morello-webkit/build-type Debug --morello-webkit/backend tier2asm

# Skip cloop hybrid because it takes ~10 hours to run.
build morello-hybrid-for-purecap-rootfs --morello-webkit/build-type Debug --morello-webkit/backend tier1asm
build morello-hybrid-for-purecap-rootfs --morello-webkit/build-type Debug --morello-webkit/backend tier2asm

# TODO: Also test other variations (e.g. --morello-webkit/jsheapoffsets).

timestamp "Running tests..."
export PYTHONPATH="$CHERIBUILD_DIR"/test-scripts
python3 .buildbot-run-and-test.py                                       \
    --architecture morello-purecap                                      \
    --qemu-cmd "$CHERI_RO_DIR"/output/sdk/bin/qemu-system-morello       \
    --bios edk2-aarch64-code.fd                                         \
    --disk-image "$CHERI_RO_DIR"/output/cheribsd-morello-purecap.img    \
    --build-dir "$TARGET_FILES_DIR"                                     \
    --ssh-port 10042
timestamp "Tests complete."
