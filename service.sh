#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

ART_UPDATED_MARKER="$MODDIR/art_update_detected"
ENABLE_SESSION_ABANDON_MARKER="$MODDIR/enable_session_abandon"
DISABLE_SESSION_GUARD_MARKER="$MODDIR/disable_session_guard"
SESSION_POLL_SECONDS=30
SESSION_FULL_SCAN_CYCLES=10
SESSION_TEST_MODE=0
SESSION_GUARD_DUMPSYS_FILE="${SESSION_GUARD_DUMPSYS_FILE:-}"
SESSION_ABANDON_REQUESTED_IDS=""

log() {
  entry="[service] $(date '+%F %T') $*"

  if [ "$SESSION_TEST_MODE" -eq 1 ]; then
    echo "$entry"
  else
    echo "$entry" >> "$LOG"
  fi
}

rotate_log() {
  if [ -f "$LOG" ]; then
    size="$(stat -c %s "$LOG" 2>/dev/null)"
    if [ -n "$size" ] && [ "$size" -gt 262144 ]; then
      mv "$LOG" "$LOG.old" 2>/dev/null
    fi
  fi
}

has_conflicting_module() {
  for base in /data/adb/modules /data/adb/modules_update; do
    for id in ART_Uninstall ART_fix; do
      conflict_dir="$base/$id"

      if [ -d "$conflict_dir" ] &&
         [ ! -f "$conflict_dir/remove" ] &&
         [ ! -f "$conflict_dir/disable" ]; then
        return 0
      fi
    done
  done

  return 1
}

update_description() {
  desc="$1"
  tmp="$MODDIR/module.prop.tmp"

  [ -f "$MODDIR/module.prop" ] || return

  grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  echo "description=$desc" >> "$tmp"
  mv "$tmp" "$MODDIR/module.prop" 2>/dev/null
}

get_android_sdk() {
  getprop ro.build.version.sdk 2>/dev/null
}

get_android_release() {
  getprop ro.build.version.release 2>/dev/null
}

android_label() {
  release="$(get_android_release)"
  sdk="$(get_android_sdk)"

  [ -n "$release" ] || release="unknown"
  [ -n "$sdk" ] || sdk="unknown"

  echo "Android $release/API $sdk"
}

is_android_below_12() {
  sdk="$(get_android_sdk)"

  case "$sdk" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$sdk" -lt 31 ]
}

is_android_12_or_newer() {
  sdk="$(get_android_sdk)"

  case "$sdk" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$sdk" -ge 31 ]
}

wait_boot_completed() {
  update_description "[等待] 等待系統開機完成後檢查 ART 狀態。"
  log "[WAIT] Waiting for sys.boot_completed=1"

  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done

  log "[OK] Boot completed"
}

wait_package_manager_ready() {
  attempt=0

  update_description "[檢查] 等待 PackageManager 穩定後啟動 ART session guard。"

  while [ "$attempt" -lt 18 ]; do
    if pm path android 2>/dev/null | grep -q '^package:'; then
      log "[OK] PackageManager ready"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 10
  done

  log "[錯誤] PackageManager 等待 180 秒後仍不可用"
  update_description "[錯誤] PackageManager 不可用，ART session guard 將持續重試。"
  return 1
}

ensure_modulemetadata_present() {
  # 重要：
  # 不要 disable / uninstall com.google.android.modulemetadata 主套件。
  # 某些 ROM 在 system_server 啟動時會呼叫 getInstalledModules。
  # 如果主套件被 user 0 uninstall，可能造成 system_server bootloop。
  if ! pm list packages --user 0 2>/dev/null | grep -q "^package:com.google.android.modulemetadata$"; then
    log "[修復] com.google.android.modulemetadata 在 user 0 不存在，嘗試 install-existing"
    pm install-existing --user 0 com.google.android.modulemetadata >> "$LOG" 2>&1
  fi

  if pm list packages --user 0 -d 2>/dev/null |
     grep -q "^package:com.google.android.modulemetadata$"; then
    if pm enable --user 0 com.google.android.modulemetadata >> "$LOG" 2>&1; then
      log "[修復] 已重新啟用 com.google.android.modulemetadata 主套件"
    else
      log "[警告] 無法重新啟用 com.google.android.modulemetadata 主套件"
    fi
    return
  fi

  log "[正常] com.google.android.modulemetadata 主套件已啟用"
}

get_package_dump() {
  if [ -n "$SESSION_GUARD_DUMPSYS_FILE" ] && [ -f "$SESSION_GUARD_DUMPSYS_FILE" ]; then
    cat "$SESSION_GUARD_DUMPSYS_FILE"
  else
    dumpsys package 2>/dev/null
  fi
}

get_staged_session_records() {
  get_package_dump | awk '
    function emit_session() {
      if (session_id != "" && is_staged == "true") {
        print session_id "|" parent_id "|" package_name "|" is_applied "|" is_failed "|" is_ready "|" is_destroyed
      }

      session_id = ""
      parent_id = ""
      package_name = ""
      is_staged = ""
      is_applied = ""
      is_failed = ""
      is_ready = ""
      is_destroyed = ""
    }

    /^[[:space:]]*Session [0-9][0-9]*:$/ {
      emit_session()
      session_id = $2
      sub(/:$/, "", session_id)
      next
    }

    session_id != "" {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^appPackageName=/) {
          split($i, value, "=")
          package_name = value[2]
        } else if ($i ~ /^params\.isStaged=/) {
          split($i, value, "=")
          is_staged = value[2]
        } else if ($i ~ /^mParentSessionId=/) {
          split($i, value, "=")
          parent_id = value[2]
        } else if ($i ~ /^mStagedSessionApplied=/) {
          split($i, value, "=")
          is_applied = value[2]
        } else if ($i ~ /^mStagedSessionFailed=/) {
          split($i, value, "=")
          is_failed = value[2]
        } else if ($i ~ /^mStagedSessionReady=/) {
          split($i, value, "=")
          is_ready = value[2]
        } else if ($i ~ /^mDestroyed=/) {
          split($i, value, "=")
          is_destroyed = value[2]
        }
      }
    }

    /^[[:space:]]*Historical install sessions:/ {
      emit_session()
      exit
    }

    END {
      emit_session()
    }
  '
}

get_art_parent_session_ids() {
  records="$1"

  printf '%s\n' "$records" \
    | awk -F '|' '
        $3 == "com.google.android.art" || $3 == "com.android.art" {
          if ($2 != "" && $2 != "-1") {
            print $2
          } else {
            print $1
          }
        }
      ' \
    | sort -u
}

get_session_record() {
  records="$1"
  target_id="$2"

  printf '%s\n' "$records" \
    | awk -F '|' -v target="$target_id" '$1 == target { print; exit }'
}

session_guard_mode() {
  if [ -f "$ENABLE_SESSION_ABANDON_MARKER" ]; then
    echo "abandon"
  else
    echo "monitor"
  fi
}

abandon_art_parent_session() {
  parent_id="$1"

  log "[SESSION] 取消包含 ART 的父層 staged train: $parent_id"
  abandon_output="$(cmd package install-abandon "$parent_id" 2>&1)"
  rc=$?

  if [ -n "$abandon_output" ]; then
    log "[SESSION] install-abandon output: $abandon_output"
  fi

  if [ "$rc" -eq 0 ]; then
    SESSION_ABANDON_REQUESTED_IDS="$SESSION_ABANDON_REQUESTED_IDS $parent_id"
    log "[SESSION] 已送出取消請求: parent=$parent_id"
    update_description "[處理] 已送出 ART Mainline train 取消請求。Session=$parent_id。"
    return 0
  fi

  log "[錯誤] 無法取消 ART staged train: parent=$parent_id rc=$rc"
  update_description "[錯誤] 偵測到 ART staged train，但取消失敗。Session=$parent_id。"
  return 1
}

check_art_staged_sessions() {
  mode="$1"

  if [ "$SESSION_TEST_MODE" -ne 1 ]; then
    package_probe="$(pm path android 2>&1)"
    if ! printf '%s\n' "$package_probe" | grep -q '^package:'; then
      log "[警告] PackageInstaller staged session 查詢失敗"
      return 1
    fi
  fi

  records="$(get_staged_session_records)"
  art_parent_ids="$(get_art_parent_session_ids "$records")"

  [ -n "$art_parent_ids" ] || return 0

  for parent_id in $art_parent_ids; do
    record="$(get_session_record "$records" "$parent_id")"
    [ -n "$record" ] || continue

    old_ifs="$IFS"
    IFS='|'
    read -r session_id ignored_parent package_name is_applied is_failed is_ready is_destroyed <<EOF
$record
EOF
    IFS="$old_ifs"

    if [ "$SESSION_TEST_MODE" -eq 1 ]; then
      log "[SESSION] ART parent=$session_id package=$package_name applied=$is_applied failed=$is_failed ready=$is_ready destroyed=$is_destroyed"
    fi

    [ "$is_applied" = "true" ] && continue
    [ "$is_failed" = "true" ] && continue
    [ "$is_destroyed" = "true" ] && continue

    log "[SESSION] 偵測到 ART staged train: parent=$session_id ready=$is_ready mode=$mode"
    update_description "[偵測] ART Mainline staged train。Session=$session_id Ready=$is_ready Mode=$mode。"

    if [ "$mode" = "abandon" ]; then
      case " $SESSION_ABANDON_REQUESTED_IDS " in
        *" $session_id "*)
          log "[SESSION] 已送出取消請求，等待 PackageInstaller 完成: parent=$session_id"
          ;;
        *)
          abandon_art_parent_session "$session_id"
          ;;
      esac
    else
      log "[SESSION] monitor-only，未取消 parent=$session_id"
    fi
  done
}

monitor_art_staged_sessions() {
  scan_cycle=1

  log "[SESSION] 持續監控已啟動，ready_poll=${SESSION_POLL_SECONDS}s full_scan_cycles=$SESSION_FULL_SCAN_CYCLES"

  while true; do
    if [ -f "$DISABLE_SESSION_GUARD_MARKER" ]; then
      sleep "$SESSION_POLL_SECONDS"
      continue
    fi

    if has_conflicting_module; then
      log "[衝突] 監控期間偵測到 ART_Uninstall 或 ART_fix，本輪停止處理"
      sleep "$SESSION_POLL_SECONDS"
      continue
    fi

    mode="$(session_guard_mode)"
    ready_parent_ids="$(cmd package list staged-sessions --only-ready --only-sessionid --only-parent 2>/dev/null)"

    if [ -n "$ready_parent_ids" ] || [ "$scan_cycle" -ge "$SESSION_FULL_SCAN_CYCLES" ]; then
      check_art_staged_sessions "$mode"
      scan_cycle=1
    else
      scan_cycle=$((scan_cycle + 1))
    fi

    sleep "$SESSION_POLL_SECONDS"
  done
}

get_art_dumpsys() {
  dumpsys package com.google.android.art 2>/dev/null
  dumpsys package com.android.art 2>/dev/null
}

has_art_apex() {
  factory_ver="$(get_factory_art_version)"

  if [ -n "$factory_ver" ]; then
    return 0
  fi

  return 1
}

handle_missing_art_apex() {
  label="$(android_label)"

  if is_android_below_12; then
    log "[略過] $label 低於 Android 12，不處理 ART Mainline。"
    update_description "[略過] $label 低於 Android 12，不處理 ART。"
    return
  fi

  if is_android_12_or_newer; then
    log "[錯誤] $label 應有 ART APEX，但未檢測到 com.google.android.art/com.android.art。"
    update_description "[錯誤] $label 未檢測到 ART APEX，請檢查 ROM dumpsys。"
    return
  fi

  log "[錯誤] 無法判斷 Android 版本，且未檢測到 ART APEX。"
  update_description "[錯誤] 未檢測到 ART APEX，且無法判斷 Android 版本。"
}

get_active_art_version() {
  get_art_dumpsys \
    | sed -n '/Active APEX packages:/,/Inactive APEX packages:/p' \
    | sed -n \
        -e 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' \
        -e 's/^[[:space:]]*Version: \([0-9][0-9]*\).*/\1/p' \
    | head -n 1
}

get_factory_art_version() {
  get_art_dumpsys \
    | sed -n '/Factory APEX packages:/,$p' \
    | sed -n \
        -e 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' \
        -e 's/^[[:space:]]*Version: \([0-9][0-9]*\).*/\1/p' \
    | head -n 1
}

get_active_art_path() {
  get_art_dumpsys \
    | sed -n '/Active APEX packages:/,/Inactive APEX packages:/p' \
    | sed -n 's/^[[:space:]]*Path: //p' \
    | head -n 1
}

get_factory_art_path() {
  get_art_dumpsys \
    | sed -n '/Factory APEX packages:/,$p' \
    | sed -n 's/^[[:space:]]*Path: //p' \
    | head -n 1
}

is_art_updated_version() {
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  log "[ART] Active versionCode=$active_ver"
  log "[ART] Factory versionCode=$factory_ver"

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    log "[警告] 無法解析 ART versionCode"
    return 1
  fi

  if [ "$active_ver" -gt "$factory_ver" ]; then
    return 0
  fi

  return 1
}

log_art_status() {
  log "[ART] ===== ART APEX 狀態 ====="

  active_path="$(get_active_art_path)"
  factory_path="$(get_factory_art_path)"
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  log "[ART] Active path=$active_path"
  log "[ART] Factory path=$factory_path"
  log "[ART] Active versionCode=$active_ver"
  log "[ART] Factory versionCode=$factory_ver"

  get_art_dumpsys \
    | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|Version:|versionCode|IsActive|IsFactory|sourceDir' \
    >> "$LOG" 2>&1

  log "[ART] ===== ART APEX 狀態結束 ====="
}

report_active_art_state() {
  if ! has_art_apex; then
    handle_missing_art_apex
    return
  fi

  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    log "[警告] 無法解析 ART 版本，session guard 仍會繼續監控"
    update_description "[警告] 無法解析 ART 版本，ART session guard 仍在監控。"
    return
  fi

  if is_art_updated_version; then
    touch "$ART_UPDATED_MARKER"
    log "[警告] 已啟用的 ART 高於 Factory；session guard 不會直接刪除 active APEX"
    update_description "[警告] 已啟用新版 ART，不直接刪 APEX。Active=$active_ver Factory=$factory_ver。"
    return
  fi

  rm -f "$ART_UPDATED_MARKER"
  log "[正常] Active ART 不高於 Factory ART"
  update_description "[正常] ART session guard 監控中。Active=$active_ver Factory=$factory_ver。"
}

if [ "$1" = "--check-sessions" ]; then
  SESSION_TEST_MODE=1
  check_art_staged_sessions "monitor"
  exit $?
fi

log "[開始] service.sh started"

rotate_log

if has_conflicting_module; then
  log "[衝突] 偵測到 ART_Uninstall 或 ART_fix，停止 ART session guard。"
  update_description "[衝突] 請移除 ART-downgrade / ART_fix，禁止同時使用。"
  exit 0
fi

wait_boot_completed

if is_android_below_12; then
  label="$(android_label)"
  log "[略過] $label 低於 Android 12，跳過 service ART/GPSU 處理。"
  update_description "[略過] $label 低於 Android 12，不處理 ART。"
  exit 0
fi

if wait_package_manager_ready; then
  ensure_modulemetadata_present
fi

log_art_status
report_active_art_state

check_art_staged_sessions "$(session_guard_mode)"
monitor_art_staged_sessions
