#!/usr/bin/env bash

set -eu

PATH="/usr/bin:/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

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

printf '%s\n' "$art_output"
printf '%s\n' 'non-ART fixture: no match'
