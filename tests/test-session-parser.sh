#!/usr/bin/env bash

set -eu

PATH="/usr/bin:/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
module_prop_before="$(cksum "$ROOT/module.prop")"

art_output="$(
  SESSION_GUARD_DUMPSYS_FILE="$ROOT/tests/fixtures/pending-art-train.dumpsys" \
    bash "$ROOT/service.sh" --check-sessions
)"

printf '%s\n' "$art_output" \
  | grep -q 'parent=100.*applied=false.*failed=false.*ready=true'
printf '%s\n' "$art_output" \
  | grep -q 'monitor-only.*parent=100'

non_art_output="$(
  SESSION_GUARD_DUMPSYS_FILE="$ROOT/tests/fixtures/pending-non-art-train.dumpsys" \
    bash "$ROOT/service.sh" --check-sessions
)"

[ -z "$non_art_output" ]

state1_output="$(
  SESSION_GUARD_DUMPSYS_FILE="$ROOT/tests/fixtures/state1-factory-art.dumpsys" \
    bash "$ROOT/service.sh" --check-state
)"

printf '%s\n' "$state1_output" | grep -q '\[狀態1\]'
if printf '%s\n' "$state1_output" | grep -q '\[狀態2\]\|\[狀態3\]'; then
  exit 1
fi

state2_output="$(
  SESSION_GUARD_DUMPSYS_FILE="$ROOT/tests/fixtures/pending-art-train.dumpsys" \
    bash "$ROOT/service.sh" --check-state
)"

printf '%s\n' "$state2_output" | grep -q '\[狀態2\].*parent=100.*ready=true'

state3_output="$(
  SESSION_GUARD_DUMPSYS_FILE="$ROOT/tests/fixtures/state3-updated-art.dumpsys" \
    bash "$ROOT/service.sh" --check-state
)"

printf '%s\n' "$state3_output" | grep -q '\[狀態3\].*Active=340000000.*Factory=330443060'
if printf '%s\n' "$state3_output" | grep -q '\[狀態2\]'; then
  exit 1
fi

module_prop_after="$(cksum "$ROOT/module.prop")"
[ "$module_prop_before" = "$module_prop_after" ]

printf '%s\n' "$art_output"
printf '%s\n' 'non-ART fixture: no match'
printf '%s\n' 'state 1: factory ART with no pending session'
printf '%s\n' 'state 2: pending ART train waiting for reboot'
printf '%s\n' 'state 3: updated ART already active'
