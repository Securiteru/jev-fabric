#!/bin/sh
set -eu
export BEND_NO_TELEMETRY=1
cd "$(dirname "$0")/.."
version=$(bend version) || {
  printf '%s\n' 'Bend could not run; verify the compiler installation.' >&2
  exit 1
}
if [ "$version" != 'bend 2.0.34' ]; then
  printf '%s\n' \
    'Native effect ABI tested with Bend 2.0.34; review before changing compiler versions.' >&2
  exit 1
fi
mkdir -p build
bun scripts/check-native-safety.ts
bend native/main.bend -o build/jev-fabric
