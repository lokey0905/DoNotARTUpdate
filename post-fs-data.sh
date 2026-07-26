#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

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

rotate_log

if has_conflicting_module; then
  log "[衝突] 偵測到 ART_Uninstall 或 ART_fix，停止 ART session guard。"
  update_description "[衝突] 請移除 ART-downgrade / ART_fix，禁止同時使用。"
  exit 0
fi

if is_android_below_12; then
  label="$(android_label)"
  log "[略過] $label 低於 Android 12，跳過 ART session guard。"
  update_description "[略過] $label 低於 Android 12，不處理 ART。"
  exit 0
fi

update_description "[啟動] 等待系統服務啟動 ART session guard。"
log "[START] post-fs-data.sh started"
log "[安全] 不直接刪除 APEX session 或 active ART 檔案"
log "[完成] post-fs-data.sh finished，交由 service.sh 監控 PackageInstaller"
