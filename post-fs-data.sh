#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"
REBOOT_REQUIRED_MARKER="$MODDIR/reboot_required_after_art_remove"
ART_REMOVED_EARLY_MARKER="$MODDIR/updated_art_removed_early"

# 建立這個檔案可以暫時關閉 Force Remove：
# touch /data/adb/modules/DoNotARTUpdate/disable_force_remove
DISABLE_FORCE_MARKER="$MODDIR/disable_force_remove"

log() {
  echo "[post-fs-data] $(date '+%F %T') $*" >> "$LOG"
}

update_description() {
  desc="$1"
  tmp="$MODDIR/module.prop.tmp"

  [ -f "$MODDIR/module.prop" ] || return

  grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  echo "description=$desc" >> "$tmp"
  mv "$tmp" "$MODDIR/module.prop" 2>/dev/null
}

rotate_log() {
  if [ -f "$LOG" ]; then
    size="$(stat -c %s "$LOG" 2>/dev/null)"
    if [ -n "$size" ] && [ "$size" -gt 262144 ]; then
      mv "$LOG" "$LOG.old" 2>/dev/null
    fi
  fi
}

early_force_remove_updated_art() {
  if [ -f "$DISABLE_FORCE_MARKER" ]; then
    log "[略過] disable_force_remove marker 存在，開機早期 Force Remove 已停用"
    return
  fi

  removed=0

  for apex in /data/apex/active/com.android.art@*.apex /data/apex/active/com.google.android.art@*.apex; do
    [ -e "$apex" ] || continue

    case "$apex" in
      /data/apex/active/com.android.art@*.apex|/data/apex/active/com.google.android.art@*.apex)
        log "[早期移除] 偵測到 updated ART active APEX: $apex"
        rm -rf "$apex" >> "$LOG" 2>&1
        rc=$?

        if [ "$rc" -eq 0 ]; then
          log "[早期移除] 已移除: $apex"
          removed=1
        else
          log "[錯誤] 早期移除失敗 rc=$rc path=$apex"
        fi
        ;;
      *)
        log "[錯誤] 不安全路徑，停止早期移除: $apex"
        ;;
    esac
  done

  if [ "$removed" -eq 1 ]; then
    sync
    touch "$ART_REMOVED_EARLY_MARKER"
    touch "$REBOOT_REQUIRED_MARKER"
    update_description "[重啟] 開機早期已移除新版 ART，請再重開機套用。"
  fi
}

rotate_log

update_description "[啟動] 開機早期清理 staged APEX 與新版 ART 中。"
log "[START] post-fs-data.sh started"

log "[清理] 清除 staged APEX sessions: /data/apex/sessions/*"
rm -rf /data/apex/sessions/* 2>/dev/null

early_force_remove_updated_art

log "[完成] post-fs-data.sh finished"