#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

REBOOT_REQUIRED_MARKER="$MODDIR/reboot_required_after_art_remove"
ART_REMOVED_MARKER="$MODDIR/updated_art_removed"
ART_UPDATED_MARKER="$MODDIR/art_update_detected"
ART_UNSAFE_MARKER="$MODDIR/unsafe_art_path_detected"

# 建立這個檔案可以暫時關閉 Force Remove：
# touch /data/adb/modules/DoNotARTUpdate/disable_force_remove
DISABLE_FORCE_MARKER="$MODDIR/disable_force_remove"

# 建立這個檔案可以在移除新版 ART 後自動重啟：
# touch /data/adb/modules/DoNotARTUpdate/auto_reboot_after_remove
AUTO_REBOOT_MARKER="$MODDIR/auto_reboot_after_remove"

log() {
  echo "[service] $(date '+%F %T') $*" >> "$LOG"
}

rotate_log() {
  if [ -f "$LOG" ]; then
    size="$(stat -c %s "$LOG" 2>/dev/null)"
    if [ -n "$size" ] && [ "$size" -gt 262144 ]; then
      mv "$LOG" "$LOG.old" 2>/dev/null
    fi
  fi
}

update_description() {
  desc="$1"
  tmp="$MODDIR/module.prop.tmp"

  [ -f "$MODDIR/module.prop" ] || return

  grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  echo "description=$desc" >> "$tmp"
  mv "$tmp" "$MODDIR/module.prop" 2>/dev/null
}

wait_boot_completed() {
  update_description "[等待] 等待系統開機完成後檢查 ART 狀態。"
  log "[WAIT] Waiting for sys.boot_completed=1"

  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done

  update_description "[檢查] 系統已開機，等待 PackageManager 穩定後檢查 ART。"

  sleep 30
  log "[OK] Boot completed"
}

clear_apex_sessions_late() {
  log "[清理] 再次清除 staged APEX sessions: /data/apex/sessions/*"
  rm -rf /data/apex/sessions/* 2>/dev/null
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

  pm enable --user 0 com.google.android.modulemetadata >> "$LOG" 2>&1
  log "[正常] 保持 com.google.android.modulemetadata 主套件啟用"
}

disable_gpsu_overlay_only() {
  log "[GPSU] 僅停用 modulemetadata overlay"

  # 只停用 overlay，不碰 com.google.android.modulemetadata 主套件。
  pm disable-user --user 0 com.google.android.overlay.modules.modulemetadata.forframework >> "$LOG" 2>&1

  log "[資訊] modulemetadata 套件狀態："
  pm list packages --user 0 2>/dev/null | grep -i modulemetadata >> "$LOG" 2>&1
  pm list packages --user 0 -d 2>/dev/null | grep -i modulemetadata >> "$LOG" 2>&1
}

get_art_dumpsys() {
  dumpsys package com.google.android.art 2>/dev/null
}

has_google_art_apex() {
  factory_ver="$(get_factory_art_version)"

  if [ -n "$factory_ver" ]; then
    return 0
  fi

  return 1
}

get_active_art_version() {
  get_art_dumpsys \
    | sed -n '/Active APEX packages:/,/Inactive APEX packages:/p' \
    | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' \
    | head -n 1
}

get_factory_art_version() {
  get_art_dumpsys \
    | sed -n '/Factory APEX packages:/,$p' \
    | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' \
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
    | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|versionCode|sourceDir' \
    >> "$LOG" 2>&1

  log "[ART] ===== ART APEX 狀態結束 ====="
}

cleanup_markers_if_art_ok() {
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  if [ -z "$active_ver" ] && [ -n "$factory_ver" ]; then
    log "[重啟] Active ART 為空，但 Factory ART 存在。保留重啟提示。"
    touch "$REBOOT_REQUIRED_MARKER"
    update_description "[重啟] 新版 ART 已移除，請再重開機套用。Factory=$factory_ver。"
    return
  fi

  if is_art_updated_version; then
    touch "$ART_UPDATED_MARKER"
    return
  fi

  rm -f "$ART_UPDATED_MARKER"
  rm -f "$REBOOT_REQUIRED_MARKER"
  rm -f "$ART_UNSAFE_MARKER"

  if [ -n "$active_ver" ] && [ -n "$factory_ver" ]; then
    update_description "[正常] ART 已是內建等效版本。Active=$active_ver Factory=$factory_ver。"
  else
    update_description "[正常] 未偵測到新版 ART，或此裝置無 Google ART APEX。"
  fi
}

force_remove_updated_art_apex() {
  if [ -f "$DISABLE_FORCE_MARKER" ]; then
    log "[略過] disable_force_remove marker 存在，Force Remove 已停用"
    update_description "[略過] Force Remove 已停用，只監控 ART 狀態。"
    return
  fi

  if ! has_google_art_apex; then
    log "[略過] 未找到可解析的 Google ART Factory 版本。Android 11 或更舊版本通常不需要處理 ART 遠端更新。"
    update_description "[略過] 未找到可解析的 Google ART Factory 版本。Android 11 或更舊版本通常不需要處理 ART 遠端更新。"
    return
  fi

  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"
  active_path="$(get_active_art_path)"
  
  if [ -z "$active_ver" ] && [ -n "$factory_ver" ]; then
    log "[重啟] Active ART 為空，但 Factory ART 存在。可能已移除新版 ART，等待重開機重建 active ART。"
    touch "$REBOOT_REQUIRED_MARKER"
    update_description "[重啟] 新版 ART 已移除，請再重開機套用。Factory=$factory_ver。"
    return
  fi

  if ! is_art_updated_version; then
    log "[正常] Active ART 不高於 Factory ART，不需要移除"
    cleanup_markers_if_art_ok
    return
  fi

  log "[警告] 偵測到新版 ART"
  log "[ART] Active path=$active_path"
  log "[ART] Active versionCode=$active_ver"
  log "[ART] Factory versionCode=$factory_ver"

  if [ -z "$active_path" ] || [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    log "[錯誤] 無法解析 ART path/version，停止 Force Remove"
    update_description "[錯誤] 偵測到新版 ART，但無法解析路徑或版本，已停止移除。"
    return
  fi

  case "$active_path" in
    /data/apex/active/com.android.art@*.apex|/data/apex/active/com.google.android.art@*.apex)
      log "[移除] 移除新版 ART APEX: $active_path"

      rm -rf "$active_path" >> "$LOG" 2>&1
      rc=$?

      sync

      if [ "$rc" -eq 0 ]; then
        log "[重啟] 已移除新版 ART APEX，需要重開機套用"

        touch "$ART_REMOVED_MARKER"
        touch "$REBOOT_REQUIRED_MARKER"
        rm -f "$ART_UNSAFE_MARKER"

        update_description "[重啟] 已移除新版 ART，請重開機套用。Active=$active_ver Factory=$factory_ver。"

        if [ -f "$AUTO_REBOOT_MARKER" ]; then
          log "[重啟] 偵測到 auto_reboot_after_remove marker，10 秒後自動重啟"
          update_description "[重啟] 已移除新版 ART，10 秒後自動重啟。"
          sleep 10
          reboot
        fi
      else
        log "[錯誤] 移除新版 ART APEX 失敗，rc=$rc"
        update_description "[錯誤] 偵測到新版 ART，但移除失敗。Active=$active_ver Factory=$factory_ver。"
      fi
      ;;
    *)
      log "[錯誤] ART 路徑不安全，停止移除: $active_path"

      touch "$ART_UNSAFE_MARKER"
      update_description "[錯誤] ART 路徑不安全，已停止移除。"
      ;;
  esac
}

log "[開始] service.sh started"

rotate_log
wait_boot_completed

ensure_modulemetadata_present
disable_gpsu_overlay_only
clear_apex_sessions_late

log_art_status
force_remove_updated_art_apex

log "[完成] service.sh finished"