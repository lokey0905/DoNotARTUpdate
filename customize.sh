#!/system/bin/sh

SKIPUNZIP=0

LOG="$MODPATH/gpsu_art_guard.log"

ui() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    echo "$1"
  fi
}

log() {
  echo "[install] $(date '+%F %T') $*" >> "$LOG"
}

update_description() {
  desc="$1"
  tmp="$MODPATH/module.prop.tmp"

  [ -f "$MODPATH/module.prop" ] || return

  grep -v '^description=' "$MODPATH/module.prop" > "$tmp" 2>/dev/null
  echo "description=$desc" >> "$tmp"
  mv "$tmp" "$MODPATH/module.prop" 2>/dev/null
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

abort_install() {
  msg="$1"

  ui "- $msg"
  update_description "$msg"
  log "$msg"

  if command -v abort >/dev/null 2>&1; then
    abort "$msg"
  fi

  exit 1
}

check_conflicting_modules() {
  for base in /data/adb/modules /data/adb/modules_update; do
    for id in ART_Uninstall ART_fix; do
      conflict_dir="$base/$id"

      if [ -d "$conflict_dir" ] &&
         [ ! -f "$conflict_dir/remove" ] &&
         [ ! -f "$conflict_dir/disable" ]; then
        ui "! 偵測到衝突模組：$id"
        ui "! DoNotARTUpdate 不可與 ART-downgrade / ART_fix 同時使用"
        ui "! 請先移除衝突模組並重開機後再安裝"
        abort_install "[衝突] 偵測到 $id，請先移除 ART-downgrade / ART_fix 並重開機。"
      fi
    done
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

check_art_on_install() {
  ui ""
  ui "*******************************"
  ui " Do Not ART Update"
  ui " 安裝時 ART 狀態檢查"
  ui "*******************************"
  ui ""

  log "[開始] 安裝時 ART 檢查"
  android_info="$(android_label)"

  ui "- 系統版本: $android_info"
  log "[Android] $android_info"

  if is_android_below_12; then
    abort_install "[不支援] 僅支援 Android 12+ ART Mainline，$android_info 停止安裝。"
  fi

  if ! command -v dumpsys >/dev/null 2>&1; then
    ui "- dumpsys 不可用，略過安裝時檢查"
    update_description "[安裝] $android_info dumpsys 不可用，等待開機後檢查 ART。"
    log "[略過] dumpsys 不可用"
    return
  fi

  if ! has_art_apex; then
    if is_android_12_or_newer; then
      abort_install "[錯誤] $android_info 應有 ART APEX，但未檢測到 com.google.android.art/com.android.art。"
    fi

    abort_install "[錯誤] 未檢測到 ART APEX，且無法確認系統為 Android 12+。"
  fi

  active_path="$(get_active_art_path)"
  factory_path="$(get_factory_art_path)"
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  ui "- Active ART path: $active_path"
  ui "- Factory ART path: $factory_path"
  ui "- Active ART versionCode: $active_ver"
  ui "- Factory ART versionCode: $factory_ver"

  log "[ART] Active path=$active_path"
  log "[ART] Factory path=$factory_path"
  log "[ART] Active versionCode=$active_ver"
  log "[ART] Factory versionCode=$factory_ver"

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    ui "- 無法解析 ART 版本，等待開機後再檢查"
    update_description "[警告] 安裝時無法解析 ART 版本，等待開機後檢查。"
    log "[警告] 無法解析 ART 版本"
    return
  fi

  if [ "$active_ver" -gt "$factory_ver" ]; then
    ui "- 偵測到新版 ART"
    ui "- 開機後 service.sh 會預設 Force Remove"
    update_description "[安裝警告] 偵測到新版 ART。Active=$active_ver Factory=$factory_ver，開機後將嘗試移除。"
    log "[警告] 安裝時偵測到新版 ART"
  else
    ui "- ART 已是內建等效版本"
    update_description "[安裝正常] ART 已是內建等效版本。Active=$active_ver Factory=$factory_ver。"
    log "[正常] ART 已是內建等效版本"
  fi

  ui ""
}

check_conflicting_modules
check_art_on_install

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/module.prop" 0 0 0644
