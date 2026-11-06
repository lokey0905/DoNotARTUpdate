#!/usr/bin/env bash
set -eu
export PATH="/usr/bin:/bin:$PATH"
export TMPDIR="${TMPDIR:-/tmp}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/lib/art-guard.sh"
eval "$(declare -f guard_dump | sed '1s/guard_dump/guard_dump_real/')"
. "$ROOT/action.sh"
# Keep the real confirmation parser; fallback flow tests mock human decisions.
eval "$(declare -f action_confirm | sed '1s/action_confirm/action_confirm_real/')"
TEST_ROOT=$(mktemp -d "$TMPDIR/art-guard-tests.XXXXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
TMP_REAL=$(cd "$TMPDIR" && pwd -P)
case "$TEST_ROOT" in "$TMP_REAL"/art-guard-tests.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TOTAL=0

expect_fail() { if "$@"; then echo "Expected failure: $*"; return 1; fi; }
assert_eq() { [ "$1" = "$2" ] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1"; return 1; }; }

setup() {
  local base="$TEST_ROOT/$TOTAL"
  mkdir -p "$base/module" "$base/state" "$base/active" "$base/system/apex" "$base/modules" "$base/updates"
  guard_init "$base/module"
  G_LIB="$ROOT/lib"
  G_STATE="$base/state"
  G_MODULES="$base/modules"
  G_UPDATES="$base/updates"
  G_ACTIVE_ROOT="$base/active"
  G_DECOMPRESSED_ROOT="$base/decompressed"
  G_FACTORY_ROOTS="$base/system/apex"
  G_BOOT=boot-1
  G_LOCK="$G_STATE/lock-$G_BOOT"
  mkdir "$G_LOCK"
  printf 'test update\n' > "$G_ACTIVE_ROOT/com.google.android.art@340000000.apex"
  printf 'factory image\n' > "$base/system/apex/com.google.android.art.apex"
  cp "$ROOT/module.prop" "$G_MODULE/module.prop"
  sed -e "s|/data/apex/active|$G_ACTIVE_ROOT|g" -e "s|/system/apex|$G_FACTORY_ROOTS|g" \
    "$ROOT/tests/fixtures/state3-updated-art.dumpsys" > "$base/updated"
  sed "s|/system/apex|$G_FACTORY_ROOTS|g" "$ROOT/tests/fixtures/state1-factory-art.dumpsys" > "$base/factory"
  sed "s|/system/apex|$G_FACTORY_ROOTS|g" "$ROOT/tests/fixtures/pending-art-train.dumpsys" > "$base/pending"
  SNAPSHOT="$base/updated"
  CASE_DIR="$base"
  CANCEL_BEHAVIOR=complete
  UNINSTALL_BEHAVIOR=success
  QUERY_FAIL=0
  CONFIRM_COUNT=0
  CONFIRM_BEHAVIOR=accept
  SDK=34
  BOOT_COMPLETED=1
  : > "$base/calls"
  guard_property() {
    case "$1" in
      ro.build.version.sdk) echo "$SDK" ;;
      ro.apex.updatable) echo true ;;
      sys.boot_completed) echo "$BOOT_COMPLETED" ;;
    esac
  }
  guard_boot_id() { echo boot-1; }
  id() { echo 0; }
  sleep() { :; }
  timeout() { [ "$2" = sync ] || { echo "Unexpected external command: $*"; return 1; }; }
  guard_dump() {
    [ "$QUERY_FAIL" = 0 ] || return 1
    if [ -f "$CASE_DIR/cancelled" ]; then cat "$CASE_DIR/factory"; else cat "$SNAPSHOT"; fi
  }
  guard_command() {
    printf '%s\n' "$*" >> "$CASE_DIR/calls"
    case "$1" in
      install-abandon)
        [ "$CANCEL_BEHAVIOR" != complete ] || touch "$CASE_DIR/cancelled"
        echo Success
        ;;
      uninstall)
        case "$UNINSTALL_BEHAVIOR" in
          success) echo Success ;;
          fail) echo 'Failure [DELETE_FAILED_ABORTED: Failed to uninstall apex com.google.android.art]'; return 1 ;;
          permission) echo 'SecurityException: permission denied'; return 1 ;;
          timeout) return 124 ;;
          ambiguous) echo 'unknown response' ;;
        esac
        ;;
      *) echo "Unexpected package command $*"; return 1 ;;
    esac
  }
  action_confirm() {
    CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
    case "$CONFIRM_BEHAVIOR" in
      cancel) return 1 ;;
      cancel-second) [ "$CONFIRM_COUNT" != 2 ] || return 1 ;;
      change) SNAPSHOT="$CASE_DIR/factory" ;;
      pause) touch "$G_MODULE/disable_session_guard" ;;
    esac
  }
}

run() {
  TOTAL=$((TOTAL + 1))
  # Each test gets a fresh process and a sandbox containing only synthetic files.
  local rc
  set +e
  (set -e; setup; "$2"; guard_cleanup) > "$TEST_ROOT/output" 2>&1
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    printf 'PASS %02d %s\n' "$TOTAL" "$1"
  else
    printf 'FAIL %02d %s\n' "$TOTAL" "$1"
    cat "$TEST_ROOT/output"
    exit 1
  fi
}

modern_fields() {
  sed 's/mStagedSession/mSession/g' "$CASE_DIR/updated" > "$CASE_DIR/modern"
  SNAPSHOT="$CASE_DIR/modern"
  guard_scan
  assert_eq "$G_ART_STATE" updated
  assert_eq "$G_PENDING" ''
  assert_eq "$G_BUSY" 0
}
missing_flags() {
  sed 's/mDestroyed=false//g' "$CASE_DIR/pending" > "$CASE_DIR/bad"
  SNAPSHOT="$CASE_DIR/bad"
  expect_fail guard_scan
}
missing_parent() {
  sed 's/mParentSessionId=100/mParentSessionId=999/' "$CASE_DIR/pending" > "$CASE_DIR/bad"
  SNAPSHOT="$CASE_DIR/bad"
  expect_fail guard_scan
}
missing_child_link() {
  sed 's/mChildSessionIds=\[101\]/mChildSessionIds=[199]/' "$CASE_DIR/pending" > "$CASE_DIR/bad"
  SNAPSHOT="$CASE_DIR/bad"
  expect_fail guard_scan
}
unresolved_package() {
  sed 's/appPackageName=com.google.android.art/appPackageName=null/' "$CASE_DIR/pending" > "$CASE_DIR/bad"
  SNAPSHOT="$CASE_DIR/bad"
  expect_fail guard_scan
}
query_failure() {
  QUERY_FAIL=1
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
truncated_dump() {
  sed '/Historical install sessions:/d' "$CASE_DIR/updated" > "$CASE_DIR/bad"
  SNAPSHOT="$CASE_DIR/bad"
  expect_fail guard_scan
}
finalized_sessions() {
  SNAPSHOT="$ROOT/tests/fixtures/finalized-art-samsung.dumpsys"
  guard_scan
  assert_eq "$G_ART_STATE" factory
  assert_eq "$G_PENDING" ''
  assert_eq "$G_BUSY" 0
}
finalized_with_pending() {
  sed '/Historical install sessions:/i\Finalized install sessions:' "$CASE_DIR/pending" > "$CASE_DIR/finalized"
  SNAPSHOT="$CASE_DIR/finalized"
  guard_scan
  assert_eq "$G_PENDING" ' 100'
  assert_eq "$G_BUSY" 2
}
child_session_heading() {
  sed 's/Session 101:/Child Session 101:/' "$CASE_DIR/pending" > "$CASE_DIR/child"
  SNAPSHOT="$CASE_DIR/child"
  guard_scan
  assert_eq "$G_PENDING" ' 100'
}
samsung_active_sessions() {
  SNAPSHOT="$ROOT/tests/fixtures/pending-art-samsung.dumpsys"
  guard_scan
  assert_eq "$G_ART_STATE" factory
  assert_eq "$G_PENDING" ' 100'
  assert_eq "$G_BUSY" 4
  assert_eq "$G_APEX_SAFE" false
  guard_cycle
  assert_eq "$(cat "$CASE_DIR/calls")" 'install-abandon 100'
}
samsung_broken_child() {
  sed 's/mParentSessionId=100/mParentSessionId=999/' "$ROOT/tests/fixtures/pending-art-samsung.dumpsys" > "$CASE_DIR/broken-samsung"
  SNAPSHOT="$CASE_DIR/broken-samsung"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
orphaned_sessions() {
  sed '/Historical install sessions:/i\Orphaned install sessions:' "$CASE_DIR/pending" > "$CASE_DIR/orphan"
  SNAPSHOT="$CASE_DIR/orphan"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
stdout_timeout() {
  cp "$CASE_DIR/pending" "$CASE_DIR/timed-out"
  printf "\n*** SERVICE 'package' DUMP TIMEOUT (10000ms) EXPIRED ***\n" >> "$CASE_DIR/timed-out"
  SNAPSHOT="$CASE_DIR/timed-out"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
dump_timeout_arguments() {
  timeout() {
    assert_eq "$*" '30 dumpsys -t 25 package'
    cat "$CASE_DIR/factory"
  }
  guard_dump_real > "$CASE_DIR/queried"
  cmp "$CASE_DIR/queried" "$CASE_DIR/factory"
}
ready_false() {
  sed 's/mStagedSessionReady=true/mStagedSessionReady=false/' "$CASE_DIR/pending" > "$CASE_DIR/not-ready"
  SNAPSHOT="$CASE_DIR/not-ready"
  guard_scan
  guard_report > "$CASE_DIR/report"
  grep -q 'ready=false' "$CASE_DIR/report"
}
cancel_complete() {
  SNAPSHOT="$CASE_DIR/pending"
  guard_cycle
  grep -qx 'install-abandon 100' "$CASE_DIR/calls"
  assert_eq "$G_PENDING" ''
  [ ! -f "$G_STATE/restore.state" ]
}
cancel_unconfirmed() {
  SNAPSHOT="$CASE_DIR/pending"
  CANCEL_BEHAVIOR=stuck
  for attempt in 1 2 3 4; do expect_fail guard_cycle; done
  assert_eq "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" 3
  [ ! -f "$G_STATE/restore.state" ]
}
pause_gate() {
  touch "$G_MODULE/disable_session_guard"
  guard_cycle
  expect_fail guard_restore
  [ ! -s "$CASE_DIR/calls" ]
}
disable_gate() {
  touch "$G_MODULE/disable"
  guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
conflict_gate() {
  mkdir "$G_UPDATES/ART_Uninstall"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
monitor_gate() {
  touch "$G_MODULE/monitor_only"
  guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
restore_disabled() {
  touch "$G_MODULE/disable_auto_restore"
  guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
uninstall_success() {
  guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  grep -qx 'uninstall --versionCode 340000000 com.google.android.art' "$CASE_DIR/calls"
  guard_cycle
  assert_eq "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" 1
  expect_fail guard_fallback_eligible
  [ -f "$G_ACTIVE_PATH" ]
}
post_reboot_success() {
  guard_cycle
  G_BOOT=boot-2
  SNAPSHOT="$CASE_DIR/factory"
  guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" restored
}
post_reboot_failure() {
  guard_cycle
  G_BOOT=boot-2
  expect_fail guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" verify_failed
  guard_fallback_eligible
}
uninstall_failed() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" failed
  guard_fallback_eligible
  expect_fail guard_cycle
  assert_eq "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" 1
}
uninstall_timeout() {
  UNINSTALL_BEHAVIOR=timeout
  expect_fail guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" blocked
  expect_fail guard_fallback_eligible
}
permission_failure() {
  UNINSTALL_BEHAVIOR=permission
  expect_fail guard_cycle
  expect_fail guard_fallback_eligible
}
ambiguous_success() {
  UNINSTALL_BEHAVIOR=ambiguous
  expect_fail guard_cycle
  expect_fail guard_fallback_eligible
}
apex_unsettled() {
  sed 's/State: SUCCESS/State: ACTIVATED/' "$CASE_DIR/updated" > "$CASE_DIR/unsettled"
  SNAPSHOT="$CASE_DIR/unsettled"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
apex_unknown() {
  sed '/APEX session state:/d' "$CASE_DIR/updated" > "$CASE_DIR/unknown"
  SNAPSHOT="$CASE_DIR/unknown"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
factory_never_removed() {
  SNAPSHOT="$CASE_DIR/factory"
  guard_cycle
  expect_fail action_fallback
  [ -f "$G_FACTORY_PATH" ]
  [ ! -s "$CASE_DIR/calls" ]
}
no_backup_no_fallback() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  printf 'corrupt\n' > "$R_BACKUP/artifact.apex"
  expect_fail action_fallback
  [ -f "$G_ACTIVE_PATH" ]
  assert_eq "$CONFIRM_COUNT" 0
}
fallback_cancelled() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  CONFIRM_BEHAVIOR=cancel
  expect_fail action_fallback
  [ -f "$G_ACTIVE_PATH" ]
  assert_eq "$CONFIRM_COUNT" 1
}
fallback_second_cancelled() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  CONFIRM_BEHAVIOR=cancel-second
  expect_fail action_fallback
  [ -f "$G_ACTIVE_PATH" ]
  assert_eq "$CONFIRM_COUNT" 2
}
fallback_success() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  printf 'unrelated\n' > "$G_ACTIVE_ROOT/com.android.media@999.apex"
  action_fallback
  [ ! -e "$G_ACTIVE_PATH" ]
  [ -f "$G_FACTORY_PATH" ]
  [ -f "$G_ACTIVE_ROOT/com.android.media@999.apex" ]
  [ -f "$R_BACKUP/artifact.apex" ]
  assert_eq "$CONFIRM_COUNT" 2
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  expect_fail action_fallback
}
fallback_changed() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  CONFIRM_BEHAVIOR=change
  expect_fail action_fallback
  [ -f "$G_ACTIVE_ROOT/com.google.android.art@340000000.apex" ]
}
fallback_paused() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  CONFIRM_BEHAVIOR=pause
  expect_fail action_fallback
  [ -f "$G_ACTIVE_PATH" ]
}
lock_contended() {
  (G_LOCK=''; expect_fail guard_lock; guard_cleanup)
  [ -d "$G_LOCK" ]
}
missing_tmpdir_fallback() {
  TMPDIR="$CASE_DIR/missing-manager-tmp"
  mktemp() {
    assert_eq "$*" '-d /data/local/tmp/art-guard.XXXXXXXX' || return 1
    command mktemp -d "$CASE_DIR/work.XXXXXXXX"
  }
  guard_prepare_work
  [ -d "$G_WORK" ]
  [ ! -e "$TMPDIR" ]
}
temp_creation_failure() {
  mktemp() { return 1; }
  expect_fail guard_prepare_work
  [ -n "$G_ERROR" ]
  assert_eq "$G_WORK" ''
}
temp_permission_failure() {
  chmod() { return 1; }
  expect_fail guard_prepare_work
  assert_eq "$G_ERROR" '無法限制暫存目錄權限。'
  [ -d "$G_WORK" ]
}
state_directory_failure() {
  mkdir() { return 1; }
  expect_fail guard_lock
  assert_eq "$G_ERROR" '無法建立或限制狀態目錄權限。'
}
boot_id_failure() {
  guard_boot_id() { return 1; }
  expect_fail guard_lock
  assert_eq "$G_ERROR" '無法讀取本次開機識別碼。'
}
readonly_lock_failure() {
  G_READONLY=1
  expect_fail guard_lock
  assert_eq "$G_ERROR" '唯讀模式不能取得寫入操作鎖。'
}
stats_empty() {
  guard_stats_load
  assert_eq "$S_COUNT" 0
  assert_eq "$S_LAST" ''
  printf '2\n' > "$G_STATE/cancel-$G_BOOT-100"
  guard_stats_load
  assert_eq "$S_COUNT" 0
  [ ! -e "$G_STATE/interceptions.state" ]
}
stats_confirmed_cancel() {
  SNAPSHOT="$CASE_DIR/pending"
  guard_cycle
  guard_stats_load 100
  assert_eq "$S_COUNT" 1
  assert_eq "$S_SEEN" 1
  assert_eq "$S_ID" 100
  [ -n "$S_LAST" ]
  grep -q '^description=.*本次開機成功取消 1 次.*最後成功取消：' "$G_MODULE/module.prop"
  saved="$S_LAST"
  guard_cycle
  guard_stats_load
  assert_eq "$S_COUNT" 1
  assert_eq "$S_LAST" "$saved"
}
stats_duplicate() {
  NOW='2026-11-06 10:34:59 +0800'
  date() { printf '%s\n' "$NOW"; }
  guard_stats_update 100
  NOW='2026-11-06 10:40:00 +0800'
  guard_stats_update 100
  guard_stats_load
  assert_eq "$S_COUNT" 1
  assert_eq "$S_LAST" '2026-11-06 10:34:59 +0800'
  guard_stats_update 101
  guard_stats_load
  assert_eq "$S_COUNT" 2
  assert_eq "$S_ID" 101
  assert_eq "$S_LAST" "$NOW"
}
stats_new_boot() {
  guard_stats_update 100
  G_BOOT=boot-2
  guard_stats_load
  assert_eq "$S_COUNT" 0
  assert_eq "$S_LAST" ''
  guard_stats_update
  assert_eq "$(cat "$G_STATE/interceptions.state")" 'v1|boot-2'
  guard_stats_update 100
  guard_stats_load
  assert_eq "$S_COUNT" 1
}
stats_unconfirmed() {
  SNAPSHOT="$CASE_DIR/pending"
  CANCEL_BEHAVIOR=stuck
  expect_fail guard_cycle
  guard_stats_load
  assert_eq "$S_COUNT" 0
  assert_eq "$S_LAST" ''
}
stats_failed_command() {
  SNAPSHOT="$CASE_DIR/pending"
  guard_command() {
    assert_eq "$1" install-abandon || return 1
    touch "$CASE_DIR/cancelled"
    echo Failure
    return 1
  }
  guard_cycle
  guard_stats_load
  assert_eq "$S_COUNT" 0
}
stats_changed_art() {
  SNAPSHOT="$ROOT/tests/fixtures/pending-art-samsung.dumpsys"
  guard_cycle
  guard_stats_load
  assert_eq "$S_COUNT" 0
}
stats_corrupt() {
  printf 'invalid\n' > "$G_STATE/interceptions.state"
  SNAPSHOT="$CASE_DIR/pending"
  guard_cycle
  grep -qx 'install-abandon 100' "$CASE_DIR/calls"
  expect_fail guard_stats_load
  assert_eq "$(cat "$G_STATE/interceptions.state")" invalid
  grep -q '成功取消紀錄無法讀取' "$G_MODULE/module.prop"
}
stats_atomic_failure() {
  guard_stats_update 100
  cp "$G_STATE/interceptions.state" "$CASE_DIR/history-before"
  mv() { return 1; }
  expect_fail guard_stats_update 101
  cmp "$CASE_DIR/history-before" "$G_STATE/interceptions.state"
  for file in "$G_STATE"/interceptions.*; do
    assert_eq "$file" "$G_STATE/interceptions.state"
  done
}
stats_readonly_report() {
  SNAPSHOT="$CASE_DIR/factory"
  guard_scan
  cp "$G_MODULE/module.prop" "$CASE_DIR/prop-before"
  G_READONLY=1
  guard_user_report > "$CASE_DIR/report"
  grep -q '目前使用出廠版本' "$CASE_DIR/report"
  grep -q '本次開機成功取消 0 次；最後成功取消：尚無' "$CASE_DIR/report"
  expect_fail guard_stats_update 100
  [ ! -e "$G_STATE/interceptions.state" ]
  [ ! -s "$CASE_DIR/calls" ]
  cmp "$G_MODULE/module.prop" "$CASE_DIR/prop-before"
}
old_sdk() {
  SDK=30
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
boot_not_complete() {
  BOOT_COMPLETED=0
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
state_corrupt() {
  echo 'invalid' > "$G_STATE/restore.state"
  expect_fail guard_cycle
  expect_fail action_fallback
  [ ! -s "$CASE_DIR/calls" ]
}
pending_during_reboot_wait() {
  guard_cycle
  SNAPSHOT="$CASE_DIR/pending"
  guard_cycle
  grep -qx 'install-abandon 100' "$CASE_DIR/calls"
  assert_eq "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" 2
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
}
same_version_setup() {
  sed 's/340000000/330443060/g' "$CASE_DIR/updated" > "$CASE_DIR/same-version"
  printf 'same version is not a content hash\n' > "$G_ACTIVE_ROOT/com.google.android.art@330443060.apex"
  SNAPSHOT="$CASE_DIR/same-version"
}
same_version_copy() {
  same_version_setup
  guard_scan
  assert_eq "$G_ART_STATE" same_version
  local hash
  hash=$(guard_hash "$G_ACTIVE_PATH")
  guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
  [ ! -e "$G_STATE/restore.state" ]
  assert_eq "$(guard_hash "$G_ACTIVE_PATH")" "$hash"
  grep -q 'ART 與出廠同版本' "$G_MODULE/module.prop"
  expect_fail guard_target
  expect_fail action_fallback
  assert_eq "$CONFIRM_COUNT" 0
}
same_version_pending() {
  same_version_setup
  cp "$CASE_DIR/same-version" "$CASE_DIR/factory"
  sed -e "/Active APEX packages:/,/Inactive APEX packages:/s|$G_FACTORY_ROOTS/com.google.android.art.apex|$G_ACTIVE_ROOT/com.google.android.art@330443060.apex|" \
    -e '0,/IsFactory: true/s/IsFactory: true/IsFactory: false/' \
    "$CASE_DIR/pending" > "$CASE_DIR/same-version-pending"
  SNAPSHOT="$CASE_DIR/same-version-pending"
  guard_cycle
  assert_eq "$G_ART_STATE" same_version
  grep -q '^install-abandon 100$' "$CASE_DIR/calls"
  ! grep -q '^uninstall ' "$CASE_DIR/calls"
  guard_stats_load
  assert_eq "$S_COUNT" 1
}
same_version_not_restored() {
  guard_cycle
  same_version_setup
  G_BOOT=boot-2
  guard_scan
  expect_fail guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  expect_fail action_fallback
  assert_eq "$CONFIRM_COUNT" 0
}
same_version_samsung() {
  SNAPSHOT="$ROOT/tests/fixtures/same-version-art-samsung.dumpsys"
  guard_scan
  assert_eq "$G_ART_STATE" same_version
  assert_eq "$G_ACTIVE_VERSION" 341411300
  assert_eq "$G_ACTIVE_PATH" /data/apex/active/com.android.art@341411300.apex
  guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
  guard_user_report > "$CASE_DIR/status"
  grep -q '版本與出廠相同' "$CASE_DIR/status"
}
samsung_compressed_setup() {
  local name="${1:-com.google.android.art_compressed.apex}"
  printf 'Samsung compressed factory\n' > "$G_FACTORY_ROOTS/$name"
  sed "s|com.google.android.art.apex|$name|g" "$CASE_DIR/updated" > "$CASE_DIR/samsung-compressed"
  SNAPSHOT="$CASE_DIR/samsung-compressed"
  guard_scan
}
samsung_compressed_factory() {
  samsung_compressed_setup
  guard_target
  guard_cycle
  grep -q '^uninstall --versionCode 340000000 com.google.android.art$' "$CASE_DIR/calls"
  [ -f "$G_FACTORY_PATH" ] && [ -f "$G_ACTIVE_PATH" ]
}
samsung_android_compressed_factory() {
  samsung_compressed_setup com.android.art_compressed.apex
  guard_target
}
samsung_compressed_bad_name() {
  samsung_compressed_setup com.google.android.art_compressed_other.apex
  expect_fail guard_target
  [ ! -s "$CASE_DIR/calls" ]
}
samsung_compressed_wrong_root() {
  samsung_compressed_setup
  cp "$G_FACTORY_PATH" "$CASE_DIR/com.google.android.art_compressed.apex"
  G_FACTORY_PATH="$CASE_DIR/com.google.android.art_compressed.apex"
  expect_fail guard_target
  [ ! -s "$CASE_DIR/calls" ]
}
compressed_factory() {
  mkdir "$G_DECOMPRESSED_ROOT"
  printf 'decompressed factory\n' > "$G_DECOMPRESSED_ROOT/com.google.android.art@330443060.decompressed.apex"
  printf 'compressed source\n' > "$G_FACTORY_ROOTS/com.google.android.art.capex"
  sed "s|$G_FACTORY_ROOTS/com.google.android.art.apex|$G_DECOMPRESSED_ROOT/com.google.android.art@330443060.decompressed.apex|g" \
    "$CASE_DIR/updated" > "$CASE_DIR/compressed"
  SNAPSHOT="$CASE_DIR/compressed"
  guard_scan
  guard_target
  guard_cycle
  [ -f "$G_FACTORY_PATH" ]
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
}
compressed_source_missing() {
  compressed_factory
  rm "$G_FACTORY_ROOTS/com.google.android.art.capex"
  expect_fail guard_target
}
missing_factory_file() {
  rm "$G_FACTORY_ROOTS/com.google.android.art.apex"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
noncanonical_target() {
  sed "s|$G_ACTIVE_ROOT/|$G_ACTIVE_ROOT/../active/|g" "$CASE_DIR/updated" > "$CASE_DIR/aliased"
  SNAPSHOT="$CASE_DIR/aliased"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
apex_error_text() {
  sed '/APEX session state:/a\  Failed to communicate with apexservice' "$CASE_DIR/updated" > "$CASE_DIR/error"
  SNAPSHOT="$CASE_DIR/error"
  expect_fail guard_cycle
  [ ! -s "$CASE_DIR/calls" ]
}
unsupported_session_layout() {
  sed 's/Session 100:/InstallSession id=100/' "$CASE_DIR/pending" > "$CASE_DIR/layout"
  SNAPSHOT="$CASE_DIR/layout"
  expect_fail guard_scan
}
compressed_restore_setup() {
  samsung_compressed_setup "${1:-com.google.android.art_compressed.apex}"
  guard_cycle
  COMPRESSED_SOURCE="$G_FACTORY_PATH"
  mkdir -p "$G_DECOMPRESSED_ROOT"
  cp "$G_FACTORY_ROOTS/com.google.android.art.apex" "$CASE_DIR/expected-payload"
  cp "$CASE_DIR/expected-payload" "$G_DECOMPRESSED_ROOT/com.android.art@330443060.decompressed.apex"
  sed "s|$G_FACTORY_ROOTS/com.google.android.art.apex|$G_DECOMPRESSED_ROOT/com.android.art@330443060.decompressed.apex|g" \
    "$CASE_DIR/factory" > "$CASE_DIR/restored-compressed"
  SNAPSHOT="$CASE_DIR/restored-compressed"
  G_BOOT=boot-2
  timeout() {
    assert_eq "$1" 30
    [ "$2" = unzip ] || return 1
    shift
    "$@"
  }
  unzip() {
    assert_eq "$1" -p
    assert_eq "$2" "$COMPRESSED_SOURCE"
    assert_eq "$3" original_apex
    cat "$CASE_DIR/expected-payload"
  }
  guard_scan
}
compressed_restore_success() {
  compressed_restore_setup
  guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" restored
  assert_eq "$(wc -l < "$CASE_DIR/calls" | tr -d ' ')" 1
  [ ! -e "$G_WORK/factory-payload.apex" ]
}
capex_restore_success() {
  compressed_restore_setup com.google.android.art.capex
  guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" restored
}
compressed_restore_mismatch() {
  compressed_restore_setup
  printf 'different factory contents\n' > "$G_FACTORY_PATH"
  expect_fail guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  [ ! -e "$G_WORK/factory-payload.apex" ]
}
compressed_restore_missing() {
  compressed_restore_setup
  rm "$COMPRESSED_SOURCE"
  expect_fail guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
}
compressed_restore_bad_name() {
  compressed_restore_setup
  G_FACTORY_PATH="$G_DECOMPRESSED_ROOT/not-art.decompressed.apex"
  G_ACTIVE_PATH="$G_FACTORY_PATH"
  cp "$CASE_DIR/expected-payload" "$G_FACTORY_PATH"
  expect_fail guard_verify_restore
}
compressed_restore_noncanonical() {
  compressed_restore_setup
  readlink() {
    if [ "$2" = "$COMPRESSED_SOURCE" ]; then printf '%s\n' "$CASE_DIR/elsewhere"; else command readlink "$@"; fi
  }
  expect_fail guard_verify_restore
}
compressed_restore_read_error() {
  compressed_restore_setup
  unzip() { cat "$CASE_DIR/expected-payload"; return 1; }
  expect_fail guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  [ ! -e "$G_WORK/factory-payload.apex" ]
}
compressed_restore_timeout() {
  compressed_restore_setup
  timeout() { cat "$CASE_DIR/expected-payload"; return 124; }
  expect_fail guard_verify_restore
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
  [ ! -e "$G_WORK/factory-payload.apex" ]
}
new_rom_during_restore() {
  guard_cycle
  G_BOOT=boot-2
  sed 's/330443060/350000000/g' "$CASE_DIR/factory" > "$CASE_DIR/new-rom"
  SNAPSHOT="$CASE_DIR/new-rom"
  expect_fail guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" pending_reboot
}
no_auto_raw_delete() {
  UNINSTALL_BEHAVIOR=fail
  expect_fail guard_cycle
  expect_fail guard_cycle
  [ -f "$G_ACTIVE_PATH" ]
  assert_eq "$CONFIRM_COUNT" 0
}
interrupted_request() {
  guard_cycle
  guard_save_restore requested
  G_BOOT=boot-2
  expect_fail guard_cycle
  guard_load_restore
  assert_eq "$R_STATUS" blocked
  expect_fail guard_fallback_eligible
}
input_setup() {
  guard_prepare_work
  getevent() { printf '%s\n' "$INPUT_EVENT"; }
  timeout() { shift; "$@"; }
  sleep() { command sleep 0.01; }
}
input_volume_up() {
  input_setup
  INPUT_EVENT='/dev/input/event0: EV_KEY KEY_VOLUMEUP UP'
  action_confirm_real 'test up'
  assert_eq "$ACTION_INPUT_PID" ''
}
input_volume_down() {
  input_setup
  INPUT_EVENT='/dev/input/event0: EV_KEY KEY_VOLUMEDOWN UP'
  expect_fail action_confirm_real 'test down'
}
input_press_only() {
  input_setup
  INPUT_EVENT='/dev/input/event0: EV_KEY KEY_VOLUMEUP DOWN'
  expect_fail action_confirm_real 'test press without release'
}
input_unavailable() {
  input_setup
  INPUT_EVENT=''
  expect_fail action_confirm_real 'test no input'
}

run 'modern fields and terminal parent' modern_fields
run 'missing boolean rejected' missing_flags
run 'orphan child rejected' missing_parent
run 'parent child list validated' missing_child_link
run 'unresolved package rejected' unresolved_package
run 'query error never means empty' query_failure
run 'truncated dump rejected' truncated_dump
run 'finalized Samsung ART trains are not pending' finalized_sessions
run 'finalized boundary preserves active train' finalized_with_pending
run 'child session heading supported' child_session_heading
run 'Samsung active headers select only the ART train' samsung_active_sessions
run 'Samsung child topology remains mandatory' samsung_broken_child
run 'orphaned sessions block mutations' orphaned_sessions
run 'stdout timeout blocks mutations' stdout_timeout
run 'dumpsys timeout is explicitly bounded' dump_timeout_arguments
run 'not-ready is not reboot-ready' ready_false
run 'cancel confirmed by reread' cancel_complete
run 'cancel retries bounded, no uninstall' cancel_unconfirmed
run 'pause applies to first operation' pause_gate
run 'module disable applies immediately' disable_gate
run 'staged conflicting module blocks' conflict_gate
run 'monitor-only does not mutate' monitor_gate
run 'auto restore can be disabled' restore_disabled
run 'uninstall is version-pinned and once only' uninstall_success
run 'new boot verifies factory' post_reboot_success
run 'new boot detects failed restore' post_reboot_failure
run 'definite uninstall failure enables Action only' uninstall_failed
run 'timeout does not enable raw fallback' uninstall_timeout
run 'permission failure does not enable raw fallback' permission_failure
run 'ambiguous response is not success' ambiguous_success
run 'apex activation in progress blocks restore' apex_unsettled
run 'unknown apexd state blocks restore' apex_unknown
run 'factory never removed' factory_never_removed
run 'corrupt backup blocks Action' no_backup_no_fallback
run 'first confirmation can cancel' fallback_cancelled
run 'second confirmation can cancel' fallback_second_cancelled
run 'manual fallback touches one sandbox file' fallback_success
run 'state rechecked after confirmation' fallback_changed
run 'pause rechecked after confirmation' fallback_paused
run 'lock cannot be stolen' lock_contended
run 'missing manager TMPDIR uses existing safe directory' missing_tmpdir_fallback
run 'temp creation failure has a reason' temp_creation_failure
run 'temp permission failure has a reason' temp_permission_failure
run 'state directory failure has a reason' state_directory_failure
run 'boot ID failure has a reason' boot_id_failure
run 'read-only lock failure has a reason' readonly_lock_failure
run 'old attempt counters are not successful cancellations' stats_empty
run 'only confirmed cancellation updates module description and time' stats_confirmed_cancel
run 'duplicate success does not increment or change time' stats_duplicate
run 'new boot clears both count and last-success time' stats_new_boot
run 'unconfirmed cancellation does not count' stats_unconfirmed
run 'failed command with vanished session does not count' stats_failed_command
run 'changed ART identity does not count as interception' stats_changed_art
run 'bad statistics cannot stop ART protection' stats_corrupt
run 'failed stats write preserves last good record' stats_atomic_failure
run 'human-readable status does not mutate anything' stats_readonly_report
run 'Android 11 rejected' old_sdk
run 'restore waits for completed boot' boot_not_complete
run 'corrupt journal blocks mutations' state_corrupt
run 'pending reboot still blocks subsequent updates' pending_during_reboot_wait
run 'same-version active copy is preserved without uninstall or fallback' same_version_copy
run 'same-version active copy still cancels later ART updates' same_version_pending
run 'version equality alone cannot verify a previous restore' same_version_not_restored
run 'real Samsung same-version layout is not called a newer ART' same_version_samsung
run 'Samsung compressed factory permits pinned system restore' samsung_compressed_factory
run 'Android-named compressed factory is supported' samsung_android_compressed_factory
run 'unrecognized compressed factory name remains blocked' samsung_compressed_bad_name
run 'compressed factory outside system roots remains blocked' samsung_compressed_wrong_root
run 'compressed factory is preserved' compressed_factory
run 'compressed factory needs preinstalled source' compressed_source_missing
run 'missing factory blocks uninstall' missing_factory_file
run 'noncanonical update target rejected' noncanonical_target
run 'apex service errors cannot mean settled' apex_error_text
run 'unsupported session layout rejected' unsupported_session_layout
run 'Samsung compressed-to-decompressed restore verifies payload hash' compressed_restore_success
run 'standard capex-to-decompressed restore verifies payload hash' capex_restore_success
run 'different factory payload cannot be called restored' compressed_restore_mismatch
run 'missing compressed source blocks restore verification' compressed_restore_missing
run 'unknown decompressed filename blocks restore verification' compressed_restore_bad_name
run 'noncanonical compressed source blocks restore verification' compressed_restore_noncanonical
run 'unzip failure cannot verify even matching partial output' compressed_restore_read_error
run 'unzip timeout cannot verify even matching partial output' compressed_restore_timeout
run 'ROM change is not claimed as verified restore' new_rom_during_restore
run 'background failure never raw-deletes ART' no_auto_raw_delete
run 'interrupted request is not a confirmed uninstall failure' interrupted_request
run 'real key parser accepts volume-up release' input_volume_up
run 'real key parser cancels on volume-down release' input_volume_down
run 'key press without release cannot confirm' input_press_only
run 'unavailable key input cancels' input_unavailable
printf '%s tests passed; no device commands were executed.\n' "$TOTAL"
