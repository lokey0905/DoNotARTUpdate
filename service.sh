#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib/art-guard.sh"
guard_init "$MODDIR"
trap 'guard_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
  --check-state|--check-sessions|--status)
    G_READONLY=1
    G_FIXTURE=${SESSION_GUARD_DUMPSYS_FILE:-}
    only_sessions=0
    [ "$1" != --check-sessions ] || only_sessions=1
    if guard_scan "$only_sessions"; then
      if [ "$1" = --status ]; then guard_user_report; else guard_report; fi
      exit 0
    fi
    printf '[錯誤] %s\n' "$G_ERROR"
    exit 1
    ;;
  --once) ;;
  '') G_STARTUP_WAIT=1 ;;
  *) printf 'Unknown option: %s\n' "$1"; exit 2 ;;
esac

guard_platform || { printf '%s\n' "$G_ERROR"; exit 1; }
cycle=10
while true; do
  if guard_paused; then
    if guard_lock; then
      guard_stats_update || guard_log '[紀錄警告] 本次開機統計無法更新。'
      guard_description '[已暫停] 不會取消或移除 ART 更新'
    fi
    guard_cleanup
    [ "${1:-}" != --once ] || exit 0
    sleep 30
    continue
  fi
  ready=''
  # Ready IDs are a scheduling hint, never evidence that no ART exists.
  if [ "$cycle" -lt 10 ]; then
    ready=$(guard_command list staged-sessions --only-ready --only-sessionid --only-parent 2>/dev/null)
    [ "$?" = 0 ] || cycle=10
  fi
  if [ "$cycle" -ge 10 ] || [ -n "$ready" ]; then
    if guard_lock; then
      rc=0
      guard_cycle || rc=$?
      guard_cleanup
      [ "${1:-}" != --once ] || exit "$rc"
      cycle=0
      [ "$rc" = 0 ] || cycle=10
    else
      printf '[等待] %s\n' "$G_ERROR"
      guard_cleanup
      [ "${1:-}" != --once ] || exit 1
    fi
  fi
  cycle=$((cycle + 1))
  sleep 30
done
