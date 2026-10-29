#!/bin/zsh
# Builds reaper_reabackground.dylib (universal arm64 + x86_64) and, when a
# REAPER resource folder exists, installs it into UserPlugins.
#
# vendor/ holds the few third-party headers the build needs (REAPER SDK and
# WDL swell, both by Cockos, zlib-style licence in each file). Run with
# VENDOR_SRC=<dir containing reaper-sdk/ and WDL/ checkouts> to refresh them.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "${VENDOR_SRC:-}" ]]; then
  rm -rf vendor && mkdir -p vendor/WDL/swell
  cp "$VENDOR_SRC/reaper-sdk/sdk/reaper_plugin.h" vendor/
  for f in swell.h swell-types.h swell-functions.h swell-modstub.mm; do
    cp "$VENDOR_SRC/WDL/WDL/swell/$f" vendor/WDL/swell/
  done
fi

OUT=reaper_reabackground.dylib
clang++ -std=c++17 -ObjC++ -fno-objc-arc -dynamiclib -O2 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -DSWELL_PROVIDED_BY_APP \
  -Ivendor -Ivendor/WDL -Ivendor/WDL/swell \
  -framework Cocoa -framework Metal -framework QuartzCore \
  -framework AVFoundation -framework CoreMedia -framework ImageIO \
  -Wno-deprecated-declarations \
  -o "$OUT" ReaBackground.mm vendor/WDL/swell/swell-modstub.mm

DEST="$HOME/Library/Application Support/REAPER/UserPlugins"
if [[ -d "$DEST" ]]; then
  cp "$OUT" "$DEST/"
  echo "installed $DEST/$OUT (restart REAPER)"
else
  echo "built $OUT"
fi
