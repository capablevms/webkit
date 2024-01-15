#!/bin/sh
#
# Copyright (c) 2022 Arm Ltd.
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# This is designed to be run on a CHERI target by .buildbot.sh. Notably, it
# expects a directory layout like this:
#
#   $PWD
#   +-- .buildbot-test.sh (this script)
#   +-- builds
#   |   +-- build-type_debug_backend_cloop
#   |   |   +-- bin
#   |   |   |   +-- jsc
#   |   |   +-- lib
#   |   |       +-- libJavaScriptCore.so
#   |   |       ...
#   |   +-- build-type_debug_backend_tier1asm
#   |   |   ...
#   |   ...
#   +-- sunspider-1.0.1
#       ...

echo "$PWD:"
du -hs *
echo "$PWD/builds:"
du -hs builds/*

echo "Disabling revocation to work around https://github.com/CTSRD-CHERI/cheribsd/issues/1964"
sysctl security.cheri.runtime_revocation_default=0

failures=''
# Run higher tiers first (ls -r). They are most complicated, most likely to
# receive development, and run a lot faster than lower tiers.
for build in $(ls -r builds/); do
  for ss in sunspider-*; do
    echo "==== $ss on $build ===="
    while read name; do
      js="$ss/$name.js"
      # Recent cheribuilds produce jsc binaries with RUNPATH set, so we don't
      # need to specify the library path.
      echo "Running: \"builds/$build/bin/jsc\" \"$js\""
      if "builds/$build/bin/jsc" "$js"; then
        echo "  - PASS" >&2
      else
        failures="${failures}  - $build: $ss/$name\n"
        echo "  - FAIL" >&2
      fi
    done < $ss/LIST
  done

  # Run everything (for a given build) before declaring results. This is helpful
  # for diagnostic purposes. However, don't run the next build if this happens.
  if [ -n "$failures" ]; then
    echo -e "Some tests failed:\n$failures" >&2
    exit 1
  fi
done

