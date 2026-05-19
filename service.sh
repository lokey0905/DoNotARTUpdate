#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

SKIP_CLEAR_MARKER="$MODDIR/skip_next_apex_session_clear"
ART_ROLLBACK_MARKER="$MODDIR/art_rollback_pending"
ART_UPDATED_MARKER="$MODDIR/art_update_detected"
REBOOT_REQUIRED_MARKER="$MODDIR/reboot_required_for_art_rollback"

log() {
  echo "[service] $(date '+%F %T') $*" >> "$LOG"
}

wait_boot_completed() {
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done

  # 等 PackageManager / RollbackManager 穩定
  sleep 30
}

disable_gpsu_delivery() {
  log "Disabling Google Play System Update metadata packages..."

  pm disable-user --user 0 com.google.android.modulemetadata >> "$LOG" 2>&1
  pm disable-user --user 0 com.google.android.overlay.modules.modulemetadata.forframework >> "$LOG" 2>&1

  cmd package disable-user --user 0 com.google.android.modulemetadata >> "$LOG" 2>&1
  cmd package disable-user --user 0 com.google.android.overlay.modules.modulemetadata.forframework >> "$LOG" 2>&1

  log "Disabled package check:"
  pm list packages --user 0 -d 2>/dev/null | grep -i modulemetadata >> "$LOG" 2>&1
}

get_art_dumpsys() {
  dumpsys package com.google.android.art 2>/dev/null
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

  log "Active ART versionCode: $active_ver"
  log "Factory ART versionCode: $factory_ver"

  if [ -z "$active_ver" ] || [ -z "$factory_ver" ]; then
    log "Unable to parse ART versionCode. Treat as not updated."
    return 1
  fi

  if [ "$active_ver" -gt "$factory_ver" ]; then
    return 0
  fi

  return 1
}

log_art_status() {
  log "===== ART APEX status ====="

  active_path="$(get_active_art_path)"
  factory_path="$(get_factory_art_path)"
  active_ver="$(get_active_art_version)"
  factory_ver="$(get_factory_art_version)"

  log "Active ART path: $active_path"
  log "Factory ART path: $factory_path"
  log "Active ART versionCode: $active_ver"
  log "Factory ART versionCode: $factory_ver"

  get_art_dumpsys \
    | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|versionCode|sourceDir' \
    >> "$LOG" 2>&1

  if is_art_updated_version; then
    log "WARNING: Active ART version is newer than factory ART."
    touch "$ART_UPDATED_MARKER"
  else
    log "ART version is factory-equivalent or not newer. Treat as safe."
    rm -f "$ART_UPDATED_MARKER"
  fi

  log "===== ART APEX status end ====="
}

has_available_art_rollback() {
  rollback_info="$(dumpsys rollback 2>/dev/null | sed -n '/Available rollbacks:/,/Historical rollbacks:/p')"

  echo "$rollback_info" | grep -q -- "-state: available"
  has_available=$?

  echo "$rollback_info" | grep -q "com.google.android.art .*->"
  has_art=$?

  if [ "$has_available" -eq 0 ] && [ "$has_art" -eq 0 ]; then
    return 0
  fi

  return 1
}

log_rollback_status() {
  log "===== Rollback status ====="

  dumpsys rollback 2>/dev/null \
    | grep -iE 'Available rollbacks|Historical rollbacks|state:|isStaged|committed|com.google.android.art|com.android.art' \
    >> "$LOG" 2>&1

  log "===== Rollback status end ====="
}

rollback_art_if_available() {
  log "===== Checking ART rollback availability ====="

  if [ -f "$ART_ROLLBACK_MARKER" ]; then
    log "ART rollback already requested. Do not request again."
    return
  fi

  if ! is_art_updated_version; then
    log "Active ART is not newer than factory. Rollback not needed."
    return
  fi

  if has_available_art_rollback; then
    log "Available ART rollback found. Running pm rollback-app com.google.android.art..."

    # 先建立 marker，避免下一次開機 post-fs-data.sh 清掉 rollback staged session
    touch "$SKIP_CLEAR_MARKER"

    OUT="$(pm rollback-app com.google.android.art 2>&1)"
    echo "$OUT" >> "$LOG"

    echo "$OUT" | grep -qi "Success"
    if [ $? -eq 0 ]; then
      log "ART rollback requested successfully. Reboot is required."
      touch "$ART_ROLLBACK_MARKER"
      touch "$REBOOT_REQUIRED_MARKER"
    else
      log "ART rollback command did not report success."
      rm -f "$SKIP_CLEAR_MARKER"
    fi
  else
    log "No available ART rollback found."
  fi

  log "===== ART rollback check end ====="
}

cleanup_rollback_markers_if_done() {
  if [ ! -f "$ART_ROLLBACK_MARKER" ] && [ ! -f "$SKIP_CLEAR_MARKER" ]; then
    return
  fi

  log "Rollback marker exists. Checking whether ART rollback has been applied..."

  if is_art_updated_version; then
    log "ART is still newer than factory. Keep rollback markers."
  else
    log "ART is no longer newer than factory. Remove rollback markers."
    rm -f "$ART_ROLLBACK_MARKER"
    rm -f "$SKIP_CLEAR_MARKER"
    rm -f "$REBOOT_REQUIRED_MARKER"
  fi
}

clear_apex_sessions_safe() {
  if [ -f "$ART_ROLLBACK_MARKER" ] || [ -f "$SKIP_CLEAR_MARKER" ]; then
    log "Rollback/skip marker exists. Skip clearing /data/apex/sessions."
    return
  fi

  log "Clearing staged APEX sessions late..."
  rm -rf /data/apex/sessions/* 2>/dev/null
}

log "service.sh started"

wait_boot_completed

disable_gpsu_delivery
cleanup_rollback_markers_if_done
clear_apex_sessions_safe
log_art_status
log_rollback_status
rollback_art_if_available

log "service.sh finished"