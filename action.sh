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

print_missing_art_apex() {
  label="$(android_label)"

  if is_android_below_12; then
    print_line "[略過] $label 低於 Android 12，不處理 ART Mainline。"
    update_description "[略過] $label 低於 Android 12，不處理 ART。"
    return
  fi

  if is_android_12_or_newer; then
    print_line "[錯誤] $label 應有 ART APEX，但未檢測到 com.google.android.art/com.android.art。"
    update_description "[錯誤] $label 未檢測到 ART APEX，請檢查 ROM dumpsys。"
    return
  fi

  print_line "[錯誤] 無法判斷 Android 版本，且未檢測到 ART APEX。"
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

print_line() {
  echo "$1"
  log "$1"
}

check_art_now() {
  print_line "==============================="
  print_line " Do Not ART Update - ART 檢查"
  print_line "==============================="
  print_line "[Android] $(android_label)"

  if ! command -v dumpsys >/dev/null 2>&1; then
    print_line "[錯誤] dumpsys 不可用，無法檢查 ART。"
    update_description "[錯誤] dumpsys 不可用，無法檢查 ART。"
    return
  fi

  if ! has_art_apex; then
    print_missing_art_apex
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
    | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|Version:|versionCode|IsActive|IsFactory|sourceDir' \
    >> "$LOG" 2>&1

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    print_line "[警告] 無法解析 ART 版本。"
    update_description "[警告] 無法解析 ART 版本。"
    return
  fi

  if [ "$active_ver" -gt "$factory_ver" ]; then
    print_line "[警告] 偵測到新版 ART。"
    print_line "[提示] session guard 不會直接刪除已啟用的 ART APEX。"
    update_description "[警告] 已啟用新版 ART，不直接刪 APEX。Active=$active_ver Factory=$factory_ver。"
  else
    print_line "[正常] ART 已是內建等效版本。"
    update_description "[正常] ART session guard 監控中。Active=$active_ver Factory=$factory_ver。"
  fi

  print_line "==============================="
}

check_art_now
print_line "[SESSION] PackageInstaller ART staged session 檢查："
"$MODDIR/service.sh" --check-sessions
