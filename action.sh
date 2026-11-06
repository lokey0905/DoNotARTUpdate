#!/system/bin/sh

action_stop_input() {
  if [ -n "${ACTION_INPUT_PID:-}" ]; then
    kill "$ACTION_INPUT_PID" 2>/dev/null || :
    wait "$ACTION_INPUT_PID" 2>/dev/null || :
    ACTION_INPUT_PID=''
  fi
}

action_read_key() {
  awk '/EV_KEY/ && $NF == "UP" && $(NF-1) ~ /^KEY_VOLUME(UP|DOWN)$/ {print $(NF-1); exit}' "$G_WORK/events"
}

action_confirm() {
  local seconds=0 key=''
  command -v getevent >/dev/null 2>&1 || { guard_error 'getevent 不可用，取消備援。'; return 1; }
  printf '%s\n' "$1" '請按一下並放開音量上確認；音量下取消，30 秒未操作自動取消。'
  : > "$G_WORK/events"
  # Track the reader itself so cancellation cannot leave an orphan getevent.
  getevent -l > "$G_WORK/events" 2>/dev/null &
  ACTION_INPUT_PID=$!
  while [ "$seconds" -lt 30 ]; do
    key=$(action_read_key)
    [ -z "$key" ] || break
    kill -0 "$ACTION_INPUT_PID" 2>/dev/null || break
    sleep 1
    seconds=$((seconds + 1))
  done
  [ -n "$key" ] || key=$(action_read_key)
  action_stop_input
  [ "$key" = KEY_VOLUMEUP ] || { guard_error '使用者取消、按鍵不可用或確認逾時。'; return 1; }
}

action_fallback() {
  local identity hash
  guard_scan && guard_fallback_eligible || return 1
  identity=$(guard_identity)
  hash="$R_HASH"
  printf '\n[最後備援] %s\n版本：%s -> %s\n目標：%s\n備份：%s\n' \
    "$G_PACKAGE" "$G_ACTIVE_VERSION" "$G_FACTORY_VERSION" "$G_ACTIVE_PATH" "$R_BACKUP"
  printf '%s\n' '只移除上述更新檔；不清 sessions、不動其他 APEX。仍可能無法開機。'
  [ ! -f "$R_BACKUP/uninstall.txt" ] || cat "$R_BACKUP/uninstall.txt"
  action_confirm '第一次確認：是否進入手動救援？' || return 1
  action_confirm '第二次確認：已確認備份與 recovery 救援方式，執行移除？' || return 1
  # Revalidate after human confirmation; the updater is outside our lock.
  guard_scan && guard_fallback_eligible || return 1
  [ "$(guard_identity)" = "$identity" ] && [ "$R_HASH" = "$hash" ] || {
    guard_error '確認期間 ART 狀態已改變，取消備援。'; return 1;
  }
  R_BOOT="$G_BOOT"
  guard_save_restore fallback_requested && timeout 15 sync || return 1
  # The sole raw APEX removal site. No globs or recursive operations.
  if ! rm -- "$G_ACTIVE_PATH" || [ -e "$G_ACTIVE_PATH" ]; then
    guard_save_restore blocked
    guard_error '移除未完成；保存現場，不自動重試。'
    return 1
  fi
  guard_save_restore pending_reboot || return 1
  guard_description "[等待重啟] 手動備援已移除指定 ART 更新檔；備份：$R_BACKUP"
  printf '%s\n' '請自行決定重開機時機；本模組不會自動重開機。'
}

action_main() {
  local moddir=${0%/*} rc
  . "$moddir/lib/art-guard.sh"
  guard_init "$moddir"
  ACTION_INPUT_PID=''
  trap 'action_stop_input; guard_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  guard_lock || { printf '[停止] %s\n' "$G_ERROR"; return 1; }
  guard_stats_update || guard_log '[紀錄警告] 本次開機統計無法更新。'
  guard_scan || { guard_description "[錯誤] $G_ERROR"; return 1; }
  guard_user_report
  rc=0
  guard_verify_restore || rc=$?
  [ "$rc" != 2 ] || return 0
  if ! action_fallback; then
    if [ "$G_ART_STATE" = factory ]; then
      guard_log '[無需手動救援] ART 仍是出廠版本，沒有移除任何檔案。'
    elif [ "$G_ART_STATE" = same_version ]; then
      guard_log '[無需手動救援] ART 與出廠同版本，保留目前副本，沒有移除任何檔案。'
    else
      guard_log "[未執行手動救援] $G_ERROR"
    fi
    return 0
  fi
}

# Tests source functions without running the device entry point.
if [ "${0##*/}" = action.sh ]; then action_main "$@"; fi
