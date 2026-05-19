#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

log() {
  echo "[action] $(date '+%F %T') $*" >> "$LOG"
}

update_description() {
  desc="$1"
  tmp="$MODDIR/module.prop.tmp"

  [ -f "$MODDIR/module.prop" ] || return

  grep -v '^description=' "$MODDIR/module.prop" > "$tmp" 2>/dev/null
  echo "description=$desc" >> "$tmp"
  mv "$tmp" "$MODDIR/module.prop" 2>/dev/null
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

print_line() {
  echo "$1"
  log "$1"
}

check_art_now() {
  print_line "==============================="
  print_line " Do Not ART Update - ART 檢查"
  print_line "==============================="

  if ! command -v dumpsys >/dev/null 2>&1; then
    print_line "[錯誤] dumpsys 不可用，無法檢查 ART。"
    update_description "[錯誤] dumpsys 不可用，無法檢查 ART。"
    return
  fi

  if ! has_google_art_apex; then
    print_line "[略過] 未找到 Google ART APEX。"
    print_line "[略過] Android 11 或更舊版本通常不需要處理 ART 遠端更新。"
    update_description "[略過] 未找到 Google ART APEX。Android 11 或更舊版本通常不需要處理 ART 遠端更新。"
    return
  fi

  active_path="$(get_active_art_path)"
  factory_path="$(get_factory_art_path)"
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  print_line "[ART] Active path=$active_path"
  print_line "[ART] Factory path=$factory_path"
  print_line "[ART] Active versionCode=$active_ver"
  print_line "[ART] Factory versionCode=$factory_ver"

  get_art_dumpsys \
    | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|versionCode|sourceDir' \
    >> "$LOG" 2>&1

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    print_line "[警告] 無法解析 ART 版本。"
    update_description "[警告] 無法解析 ART 版本。"
    return
  fi

  if [ "$active_ver" -gt "$factory_ver" ]; then
    print_line "[警告] 偵測到新版 ART。"
    print_line "[提示] 重開機時 service.sh 會預設嘗試移除新版 ART。"
    update_description "[警告] 偵測到新版 ART。Active=$active_ver Factory=$factory_ver，重開後將嘗試移除。"
  else
    print_line "[正常] ART 已是內建等效版本。"
    update_description "[正常] ART 已是內建等效版本。Active=$active_ver Factory=$factory_ver。"
  fi

  if [ -f "$MODDIR/reboot_required_after_art_remove" ]; then
    print_line "[重啟] 偵測到新版 ART 已移除標記，請重開機套用。"
    update_description "[重啟] 已移除新版 ART，請重開機套用。"
  fi

  print_line "==============================="
}

check_art_now