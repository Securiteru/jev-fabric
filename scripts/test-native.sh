#!/bin/sh
set -eu
export BEND_NO_TELEMETRY=1
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
# The safety gate in build-native.sh already checked every example module.

# Build outside Bun's test hooks, with process-group deadlines and phase evidence.
fixtures='core io fail-fast jobs jobs-streams codec codec-limits wire codec-wire-probe
  http jev-client session monitor monitor-pure policy-core time-core timers'
# Per fixture: <name>.json receipt, .pid of its deadline supervisor, .start time, .status exit code.
receipts=build/fixture-receipts
# The supervisor's exit code after SIGTERM (128 + 15).
cancelled_status=143

# Each compile is mostly single-threaded and needs ~2.3 GB, so run half the CPUs, at most 4.
default_jobs() {
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=2
  case $cpus in
    '' | *[!0-9]*) cpus=2 ;;
  esac
  limit=$((cpus / 2))
  if [ "$limit" -lt 1 ]; then
    limit=1
  fi
  if [ "$limit" -gt 4 ]; then
    limit=4
  fi
  printf '%s\n' "$limit"
}

count() {
  printf '%s\n' "$#"
}

# POSIX sh has no locals, so each function below uses its own variable names.
start_build() {
  started=$1
  printf 'Building native fixture: %s\n' "$started"
  date +%s > "$receipts/$started.start"
  (
    build/jev-fabric -- exec 300000 bend "native/tests/$started.bend" -o "build/test-$started" \
      > "$receipts/$started.json" 2>&1 &
    printf '%s\n' "$!" > "$receipts/$started.pid"
    status=0
    wait "$!" || status=$?
    # Rename so the poller never reads a half-written status.
    printf '%s\n' "$status" > "$receipts/$started.status.tmp"
    mv "$receipts/$started.status.tmp" "$receipts/$started.status"
  ) &
}

# The deadline supervisor terminates its compiler's process group on SIGTERM. Called on every
# poll after a failure, so a build whose .pid was not yet written is still caught.
cancel_builds() {
  for victim in $running; do
    if [ -f "$receipts/$victim.pid" ] && [ ! -f "$receipts/$victim.status" ]; then
      kill -TERM "$(cat "$receipts/$victim.pid")" 2>/dev/null || true
    fi
  done
}

# Prints a finished fixture's receipt; returns non-zero if its build failed.
report_build() {
  finished=$1
  status=$(cat "$receipts/$finished.status")
  elapsed=$(($(date +%s) - $(cat "$receipts/$finished.start")))
  if [ -n "$failed" ] && [ "$status" -eq "$cancelled_status" ]; then
    printf '\nCancelled native fixture: %s\n' "$finished"
    return 0
  fi
  if [ "$status" -eq 0 ]; then
    printf '\nBuilt native fixture: %s (%ss)\n' "$finished" "$elapsed"
  else
    printf '\nFAILED native fixture: %s (exit %s after %ss)\n' "$finished" "$status" "$elapsed"
  fi
  cat "$receipts/$finished.json"
  return "$status"
}

jobs=${JEV_TEST_JOBS:-$(default_jobs)}
case $jobs in
  '' | *[!0-9]* | 0*)
    printf 'JEV_TEST_JOBS must be a positive integer, got: %s\n' "$jobs" >&2
    exit 2
    ;;
esac

rm -rf "$receipts"
mkdir -p "$receipts"
pending=$fixtures
running=''
failed=''
trap cancel_builds EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\nBuilding %s native fixtures, %s at a time\n' "$(count $fixtures)" "$jobs"
while :; do
  still_running=''
  for name in $running; do
    if [ ! -f "$receipts/$name.status" ]; then
      still_running="$still_running $name"
    elif ! report_build "$name"; then
      failed=${failed:-$name}
    fi
  done
  running=$still_running
  # Fail fast: once anything failed, launch nothing more and stop the builds in flight.
  if [ -n "$failed" ]; then
    cancel_builds
  fi
  while [ -z "$failed" ] && [ -n "$pending" ] && [ "$(count $running)" -lt "$jobs" ]; do
    set -- $pending
    name=$1
    shift
    pending=$*
    start_build "$name"
    running="$running $name"
  done
  if [ -z "$running" ]; then
    break
  fi
  sleep 1
done
trap - EXIT INT TERM
if [ -n "$failed" ]; then
  printf '\nNative fixture %s failed; receipt: %s/%s.json\n' "$failed" "$receipts" "$failed" >&2
  exit 1
fi

build/test-core
build/test-jobs-streams
export JEV_NATIVE_PREBUILT=1
bun test --timeout 30000 native/tests/*.test.ts
