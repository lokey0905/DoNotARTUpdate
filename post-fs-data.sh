#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/gpsu_art_guard.log"

SKIP_CLEAR_MARKER="$MODDIR/skip_next_apex_session_clear"
ART_ROLLBACK_MARKER="$MODDIR/art_rollback_pending"

log() {
  echo "[post-fs-data] $(date '+%F %T') $*" >> "$LOG"
}

log "post-fs-data.sh started"

# 如果 service.sh 已經要求 ART rollback，下次開機不能清 /data/apex/sessions
# 否則 staged rollback 可能被清掉，導致 rollback 無法套用。
if [ -f "$SKIP_CLEAR_MARKER" ] || [ -f "$ART_ROLLBACK_MARKER" ]; then
  log "Rollback/skip marker found. Skip clearing /data/apex/sessions."
  exit 0
fi

log "Clearing staged APEX sessions early..."
rm -rf /data/apex/sessions/* 2>/dev/null
log "Done."