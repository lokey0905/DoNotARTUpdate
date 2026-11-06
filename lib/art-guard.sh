#!/system/bin/sh

# Shared by installer, service and Action. Sourcing this file has no side effects.
guard_init() {
  G_MODULE="$1"
  G_LIB="$G_MODULE/lib"
  G_STATE=/data/adb/DoNotARTUpdate
  G_MODULES=/data/adb/modules
  G_UPDATES=/data/adb/modules_update
  G_ACTIVE_ROOT=/data/apex/active
  G_DECOMPRESSED_ROOT=/data/apex/decompressed
  G_FACTORY_ROOTS='/system/apex /system_ext/apex /product/apex /vendor/apex /odm/apex'
  G_READONLY=0
  G_FIXTURE=''
  G_LOCK=''
  G_WORK=''
  G_ERROR=''
  G_BOOT=''
  G_STARTUP_WAIT=0
  G_STARTUP_FAILURES=0
  G_SCAN_ERROR=''
  G_QUERY_RC=0
}

guard_error() { G_ERROR="$*"; return 1; }
guard_boot_id() { cat /proc/sys/kernel/random/boot_id; }
guard_property() { getprop "$1"; }
guard_command() { timeout 30 cmd package "$@"; }

guard_log() {
  local size
  printf '%s\n' "$*"
  [ "$G_READONLY" = 0 ] && [ -d "$G_STATE" ] || return 0
  size=$(stat -c %s "$G_STATE/guard.log" 2>/dev/null) || size=0
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt 262144 ]; then
    mv -f "$G_STATE/guard.log" "$G_STATE/guard.log.old" || return 1
  fi
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$G_STATE/guard.log"
}

guard_description() {
  local tmp="$G_MODULE/module.prop.$$" message="$*" stats
  stats=$(guard_stats_text)
  message="$message；$stats"
  guard_log "$message"
  [ "$G_READONLY" = 0 ] && [ -f "$G_MODULE/module.prop" ] || return 0
  grep -Fxq "description=$message" "$G_MODULE/module.prop" && return 0
  grep -v '^description=' "$G_MODULE/module.prop" > "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'description=%s\n' "$message" >> "$tmp" && mv -f "$tmp" "$G_MODULE/module.prop"
}

guard_stats_load() {
  local file="$G_STATE/interceptions.state" boot data
  S_BOOT='' S_COUNT=0 S_LAST='' S_ID='' S_SEEN=0
  [ ! -L "$file" ] || return 1
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  boot=${G_BOOT:-$(guard_boot_id)}
  case "$boot" in ''|*[!a-zA-Z0-9-]*) return 1 ;; esac
  data=$(awk -v boot="$boot" -v target="${1:-}" -f "$G_LIB/parse-stats.awk" "$file") || return 1
  IFS='|' read -r S_BOOT S_COUNT S_LAST S_ID S_SEEN <<EOF
$data
EOF
}

# No ID means reset old-boot statistics only. An ID records a confirmed success.
guard_stats_update() {
  local id="${1:-}" file="$G_STATE/interceptions.state" stamp='' tmp rc=0
  [ "$G_READONLY" = 0 ] && [ -n "$G_BOOT" ] && [ -n "$G_LOCK" ] && [ -d "$G_LOCK" ] || return 1
  case "$id" in *[!0-9]*) return 1 ;; esac
  guard_stats_load "$id" || return 1
  if [ -z "$id" ]; then
    [ -n "$S_BOOT" ] && [ "$S_BOOT" != "$G_BOOT" ] || return 0
  else
    [ "$S_SEEN" != 1 ] || return 0
    stamp=$(date '+%Y-%m-%d %H:%M:%S %z') || return 1
  fi
  tmp=$(mktemp "$G_STATE/interceptions.XXXXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'v1|%s\n' "$G_BOOT" > "$tmp" || rc=1
  if [ "$S_BOOT" = "$G_BOOT" ]; then
    tail -n +2 "$file" >> "$tmp" || rc=1
  fi
  [ -z "$id" ] || printf '%s|%s\n' "$id" "$stamp" >> "$tmp" || rc=1
  if [ "$rc" = 0 ] &&
     awk -v boot="$G_BOOT" -f "$G_LIB/parse-stats.awk" "$tmp" >/dev/null &&
     mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

guard_stats_text() {
  if guard_stats_load; then
    printf '本次開機成功取消 %s 次；最後成功取消：%s' "$S_COUNT" "${S_LAST:-尚無}"
  else
    printf '成功取消紀錄無法讀取，請查看 Action'
  fi
}

guard_user_report() {
  case "$G_ART_STATE" in
    factory) printf 'ART 狀態：目前使用出廠版本，沒有已套用的 ART 更新。\n' ;;
    same_version) printf 'ART 狀態：版本與出廠相同，使用資料分區副本；保留副本，不自動解除。\n' ;;
    updated) printf 'ART 狀態：目前已套用 ART 更新。\n' ;;
    *) printf 'ART 狀態：無法確認，請查看錯誤紀錄。\n' ;;
  esac
  printf '目前版本：%s；出廠版本：%s\n' "$G_ACTIVE_VERSION" "$G_FACTORY_VERSION"
  [ -z "$G_PENDING" ] || printf '待套用的 ART 更新：%s（由背景監控嘗試取消）\n' "$G_PENDING"
  guard_stats_text
  printf '\n'
}

guard_conflicts() {
  local base id dir
  for base in "$G_MODULES" "$G_UPDATES"; do
    for id in ART_Uninstall ART_fix; do
      dir="$base/$id"
      if [ -d "$dir" ] && [ ! -f "$dir/remove" ] && [ ! -f "$dir/disable" ]; then
        guard_error "衝突模組 $id；停止處理。"
        return 0
      fi
    done
  done
  return 1
}

guard_paused() {
  local base
  for base in "$G_MODULE" "$G_MODULES/DoNotARTUpdate"; do
    if [ -f "$base/disable" ] || [ -f "$base/remove" ] || [ -f "$base/disable_session_guard" ]; then
      return 0
    fi
  done
  return 1
}

guard_monitor_only() { [ -f "$G_MODULE/monitor_only" ]; }

guard_platform() {
  local sdk
  sdk=$(guard_property ro.build.version.sdk)
  case "$sdk" in ''|*[!0-9]*) guard_error '無法確認 Android API。'; return 1 ;; esac
  [ "$sdk" -ge 31 ] || { guard_error 'Android 11 以下不支援。'; return 1; }
}

guard_allowed() {
  [ "$G_READONLY" = 0 ] || { guard_error '唯讀模式禁止寫入。'; return 1; }
  [ -n "$G_LOCK" ] && [ -d "$G_LOCK" ] || { guard_error '尚未取得操作鎖。'; return 1; }
  guard_platform || return 1
  guard_paused && { guard_error '模組已停用或暫停。'; return 1; }
  guard_conflicts && return 1
  guard_monitor_only && { guard_error '目前為 monitor-only。'; return 1; }
  return 0
}

guard_prepare_work() {
  local base="${TMPDIR:-/data/local/tmp}"
  [ -n "$G_WORK" ] && [ -d "$G_WORK" ] && return 0
  # Magisk's app shell can inherit /dev/tmp after that directory was removed.
  if [ ! -d "$base" ] || [ ! -w "$base" ]; then base=/data/local/tmp; fi
  G_WORK=$(mktemp -d "$base/art-guard.XXXXXXXX") || {
    guard_error "無法在 $base 建立查詢暫存目錄。"; return 1
  }
  chmod 700 "$G_WORK" || { guard_error '無法限制暫存目錄權限。'; return 1; }
}

guard_lock() {
  [ "$G_READONLY" = 0 ] || { guard_error '唯讀模式不能取得寫入操作鎖。'; return 1; }
  [ "$(id -u)" = 0 ] || { guard_error '需要 root。'; return 1; }
  [ ! -L "$G_STATE" ] || { guard_error '狀態目錄不可為符號連結。'; return 1; }
  mkdir -p "$G_STATE" && chmod 700 "$G_STATE" || {
    guard_error '無法建立或限制狀態目錄權限。'; return 1
  }
  G_BOOT=$(guard_boot_id) || { guard_error '無法讀取本次開機識別碼。'; return 1; }
  case "$G_BOOT" in ''|*[!a-zA-Z0-9-]*) guard_error '無效 boot ID。'; return 1 ;; esac
  # Boot-scoped mkdir is portable to root managers without flock. Never steal
  # a same-boot lock: an interrupted mutation requires inspection or a reboot.
  local lock="$G_STATE/lock-$G_BOOT"
  if ! mkdir "$lock" 2>/dev/null; then
    guard_error '其他操作持有鎖，或上次操作中斷；本輪不寫入。'
    return 1
  fi
  G_LOCK="$lock"
  printf '%s\n' "$$" > "$G_LOCK/pid" || { guard_error '無法寫入操作鎖持有者。'; return 1; }
  guard_prepare_work
}

guard_cleanup() {
  if [ -n "$G_WORK" ] && [ -d "$G_WORK" ]; then
    # Only exact files created by this process, never a recursive deletion.
    rm -f "$G_WORK/dump" "$G_WORK/error" "$G_WORK/records" "$G_WORK/events" "$G_WORK/key" "$G_WORK/factory-payload.apex" "$G_WORK/factory-error"
    rmdir "$G_WORK" 2>/dev/null
    G_WORK=''
  fi
  if [ -n "$G_LOCK" ]; then
    rm -f "$G_LOCK/pid"
    rmdir "$G_LOCK" 2>/dev/null
    G_LOCK=''
  fi
  return 0
}

guard_dump() {
  if [ "$G_READONLY" = 1 ] && [ -n "$G_FIXTURE" ]; then
    cat "$G_FIXTURE"
  else
    timeout 30 dumpsys -t 25 package
  fi
}

guard_record_query_error() {
  local tmp
  # Read-only checks must not change persistent diagnostics either.
  [ "$G_READONLY" = 0 ] && [ -n "$G_LOCK" ] && [ -d "$G_LOCK" ] || return 0
  [ ! -L "$G_STATE/query-error.log" ] && [ ! -d "$G_STATE/query-error.log" ] || return 1
  tmp=$(mktemp "$G_STATE/query-error.XXXXXXXX") || return 1
  if ! {
    printf 'time=%s\nboot=%s\nexit_code=%s\n' "$(date '+%F %T %z')" "$G_BOOT" "$G_QUERY_RC"
    printf 'command=timeout 30 dumpsys -t 25 package\n[stderr, first 16 KiB]\n'
    head -c 16384 "$G_WORK/error"
    printf '\n[stdout query errors, first 16 KiB]\n'
    grep -E '^\*\*\* SERVICE .* DUMP TIMEOUT|^Permission Denial:|^Can.t find service:' "$G_WORK/dump" | head -c 16384
    printf '\n'
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$G_STATE/query-error.log"; then
    rm -f "$tmp"
    return 1
  fi
}

guard_query_error() {
  G_SCAN_ERROR=query
  guard_error "$1"
  guard_record_query_error || guard_log '[紀錄警告] 無法保存 PackageManager 原始查詢錯誤。'
  return 1
}

guard_scan_failure_description() {
  if [ "$G_STARTUP_WAIT" = 1 ] && [ "$G_SCAN_ERROR" = query ]; then
    G_STARTUP_FAILURES=$((G_STARTUP_FAILURES + 1))
    if [ "$G_STARTUP_FAILURES" -lt 3 ]; then
      guard_description "[等待系統服務] 尚未取得 ART 狀態，30 秒後重試（$G_STARTUP_FAILURES/3）；未執行 ART 變更"
      return 0
    fi
  fi
  # A successful scan, a real parse error, or three query failures ends grace.
  G_STARTUP_WAIT=0
  guard_description "[無法確認狀態] 未執行 ART 變更：$G_ERROR"
}

guard_scan() {
  local kind one two three four five six
  G_ERROR=''
  G_SCAN_ERROR=other
  G_QUERY_RC=0
  G_PENDING=''
  G_BUSY=''
  G_DRAFTS=0
  G_APEX_SAFE=false
  G_ART_STATE=unknown
  G_PACKAGE='' G_ACTIVE_VERSION='' G_FACTORY_VERSION='' G_ACTIVE_PATH='' G_FACTORY_PATH=''
  guard_prepare_work || return 1
  guard_dump > "$G_WORK/dump" 2> "$G_WORK/error" || G_QUERY_RC=$?
  if [ "$G_QUERY_RC" != 0 ]; then
    guard_query_error 'PackageManager 查詢失敗或逾時，不能當成沒有更新。'
    return 1
  fi
  if grep -qiE 'DUMP TIMEOUT|Permission Denial|Can.t find service|Exception' "$G_WORK/error" ||
     grep -qE '^\*\*\* SERVICE .* DUMP TIMEOUT|^Permission Denial:|^Can.t find service:' "$G_WORK/dump"; then
    guard_query_error 'PackageManager 回報查詢錯誤。'
    return 1
  fi
  G_SCAN_ERROR=parse
  if ! awk -v only_sessions="${1:-0}" -f "$G_LIB/parse-state.awk" "$G_WORK/dump" > "$G_WORK/records"; then
    G_ERROR="解析失敗：$(cat "$G_WORK/records")"
    return 1
  fi
  while IFS='|' read -r kind one two three four five six; do
    case "$kind" in
      ART)
        G_PACKAGE="$one" G_ACTIVE_VERSION="$two" G_FACTORY_VERSION="$three"
        G_ACTIVE_PATH="$five" G_FACTORY_PATH="$six"
        case "$four" in
          true) G_ART_STATE=factory ;;
          false)
            G_ART_STATE=updated
            # RollbackManager can reinstall the original version under active.
            # Version equality is not proof of factory provenance or file equality.
            [ "$two" != "$three" ] || G_ART_STATE=same_version
            ;;
        esac
        ;;
      BUSY) G_BUSY="$one" ;;
      DRAFTS) G_DRAFTS="$one" ;;
      APEXSAFE) G_APEX_SAFE="$one" ;;
      PENDING) G_PENDING="$G_PENDING $one" ;;
    esac
  done < "$G_WORK/records"
  [ -n "$G_BUSY" ] || { guard_error '缺少交易狀態。'; return 1; }
  G_SCAN_ERROR=''
  G_STARTUP_WAIT=0
  G_STARTUP_FAILURES=0
}

guard_report() {
  local kind id ready committed
  if [ "$G_ART_STATE" = updated ]; then
    guard_log "[狀態3] Active=$G_ACTIVE_VERSION Factory=$G_FACTORY_VERSION Path=$G_ACTIVE_PATH"
  elif [ "$G_ART_STATE" = same_version ]; then
    guard_log "[同版本副本] Active=$G_ACTIVE_VERSION Factory=$G_FACTORY_VERSION Path=$G_ACTIVE_PATH；不自動解除。"
  elif [ "$G_ART_STATE" = factory ] && [ -z "$G_PENDING" ]; then
    guard_log "[狀態1] ART 未更新。Active=$G_ACTIVE_VERSION Factory=$G_FACTORY_VERSION"
  fi
  while IFS='|' read -r kind id ready committed; do
    [ "$kind" = PENDING ] || continue
    if [ "$ready" = true ]; then
      guard_log "[狀態2] parent=$id ready=true，等待重開機套用。"
    else
      guard_log "[狀態2] parent=$id ready=false，交易尚未就緒。"
    fi
  done < "$G_WORK/records"
  [ "${G_DRAFTS:-0}" = 0 ] || guard_log "[準備中] $G_DRAFTS 筆未提交且未就緒的交易待辨識；保留追蹤，暫緩 ART 解除。"
}

guard_cancel_pending() {
  local ids="$G_PENDING" id attempts file result rc i identity
  for id in $ids; do
    guard_allowed && guard_scan || return 1
    case " $G_PENDING " in *" $id "*) ;; *) continue ;; esac
    identity=$(guard_identity)
    file="$G_STATE/cancel-$G_BOOT-$id"
    attempts=0
    [ ! -f "$file" ] || read -r attempts < "$file"
    case "$attempts" in ''|*[!0-9]*) guard_error '取消計數損壞。'; return 1 ;; esac
    [ "$attempts" -lt 3 ] || { guard_error "交易 $id 取消三次仍未確認；停止自動重試。"; return 1; }
    printf '%s\n' "$((attempts + 1))" > "$file" || return 1
    guard_log "[取消] parent=$id；會取消同一父交易內的其他更新。"
    rc=0
    result=$(guard_command install-abandon "$id" 2>&1) || rc=$?
    guard_log "[取消回應] rc=$rc $result"
    # A successful command is only a request; read back the authoritative state.
    i=0
    while [ "$i" -lt 3 ]; do
      sleep 2
      guard_scan || return 1
      case " $G_PENDING " in *" $id "*) ;; *) break ;; esac
      i=$((i + 1))
    done
    case " $G_PENDING " in
      *" $id "*) guard_error "交易 $id 仍待處理，尚未確認取消；不執行解除更新。"; return 1 ;;
    esac
    guard_log "[取消完成] parent=$id 已不在待套用 ART 交易中。"
    # Statistics never treat an attempt, an ambiguous response, or a newly
    # activated ART as a successful interception.
    if [ "$rc" = 0 ] && printf '%s\n' "$result" | grep -qx 'Success' &&
       [ "$(guard_identity)" = "$identity" ]; then
      guard_stats_update "$id" || guard_log '[紀錄警告] 取消已完成，但成功次數與時間無法儲存。'
    else
      guard_log '[紀錄] 交易已離開待處理清單，但無法確定是成功取消，不列入統計。'
    fi
  done
}

guard_hash() {
  local result
  result=$(sha256sum "$1") || return 1
  printf '%s\n' "${result%% *}"
}

guard_target() {
  local root allowed=0 resolved base capex='' capex_count=0
  [ "$G_ART_STATE" = updated ] || { guard_error '目前不是已套用的 ART 更新版。'; return 1; }
  [ "$G_BUSY" = 0 ] && [ "$G_APEX_SAFE" = true ] || {
    guard_error '仍有 staged/APEX 交易，或無法確認 apexd 已穩定。'; return 1;
  }
  [ "$(guard_property sys.boot_completed)" = 1 ] || { guard_error '尚未完成開機，不解除更新。'; return 1; }
  [ "$(guard_property ro.apex.updatable)" = true ] || { guard_error '裝置不支援可更新 APEX。'; return 1; }
  [ -f "$G_ACTIVE_PATH" ] && [ ! -L "$G_ACTIVE_PATH" ] || { guard_error '更新檔不存在或為符號連結。'; return 1; }
  resolved=$(readlink -f "$G_ACTIVE_PATH") || return 1
  [ "$resolved" = "$G_ACTIVE_PATH" ] && [ "${resolved%/*}" = "$G_ACTIVE_ROOT" ] || {
    guard_error '更新檔不在預期的 active 目錄。'; return 1;
  }
  base=${resolved##*/}
  case "$base" in
    "com.android.art@$G_ACTIVE_VERSION.apex"|"com.google.android.art@$G_ACTIVE_VERSION.apex") ;;
    *) guard_error 'ART 更新檔名與版本不一致。'; return 1 ;;
  esac
  [ -f "$G_FACTORY_PATH" ] && [ ! -L "$G_FACTORY_PATH" ] && [ -r "$G_FACTORY_PATH" ] || {
    guard_error '缺少可讀取的內建 ART。'; return 1;
  }
  resolved=$(readlink -f "$G_FACTORY_PATH") || return 1
  [ "$resolved" = "$G_FACTORY_PATH" ] || { guard_error '內建 ART 路徑有歧義。'; return 1; }
  for root in $G_FACTORY_ROOTS; do
    [ "${resolved%/*}" != "$root" ] || allowed=1
  done
  if [ "${resolved%/*}" = "$G_DECOMPRESSED_ROOT" ]; then
    case "${resolved##*/}" in
      "com.android.art@$G_FACTORY_VERSION.decompressed.apex") base=com.android.art ;;
      "com.google.android.art@$G_FACTORY_VERSION.decompressed.apex") base=com.google.android.art ;;
      *) guard_error '內建解壓 ART 檔名與版本不符。'; return 1 ;;
    esac
    # A decompressed factory image is read-only input, never a removal target.
    # Also require its preinstalled compressed source on a system partition.
    for root in $G_FACTORY_ROOTS; do
      capex="$root/$base.capex"
      if [ -f "$capex" ] && [ -r "$capex" ] && [ ! -L "$capex" ] && [ "$(readlink -f "$capex")" = "$capex" ]; then
        capex_count=$((capex_count + 1))
      fi
    done
    [ "$capex_count" = 1 ] || { guard_error '無法唯一確認內建 compressed ART 來源。'; return 1; }
    return 0
  fi
  [ "$allowed" = 1 ] || { guard_error '內建 ART 不在支援的系統 APEX 目錄。'; return 1; }
  case "${resolved##*/}" in
    com.android.art.apex|com.android.art.capex|com.google.android.art.apex|com.google.android.art.capex|com.android.art_compressed.apex|com.google.android.art_compressed.apex) ;;
    *) guard_error '無法確認內建 ART 檔名。'; return 1 ;;
  esac
  [ "$G_ACTIVE_PATH" != "$G_FACTORY_PATH" ] || return 1
}

guard_identity() {
  printf '%s|%s|%s|%s|%s\n' "$G_PACKAGE" "$G_ACTIVE_VERSION" "$G_ACTIVE_PATH" "$G_FACTORY_VERSION" "$G_FACTORY_PATH"
}

guard_load_restore() {
  R_STATUS='' R_BOOT='' R_ID='' R_BACKUP='' R_HASH=''
  [ -f "$G_STATE/restore.state" ] || return 0
  local pkg ver path fver fpath extra
  IFS='|' read -r R_STATUS R_BOOT pkg ver path fver fpath R_BACKUP R_HASH extra < "$G_STATE/restore.state" || return 1
  case "$R_STATUS" in requested|pending_reboot|failed|blocked|verify_failed|restored|fallback_requested) ;; *) return 1 ;; esac
  [ -z "$extra" ] && [ -n "$R_HASH" ] || return 1
  R_ID="$pkg|$ver|$path|$fver|$fpath"
}

guard_save_restore() {
  local tmp="$G_STATE/restore.state.$$"
  R_STATUS="$1"
  printf '%s|%s|%s|%s|%s\n' "$R_STATUS" "$R_BOOT" "$R_ID" "$R_BACKUP" "$R_HASH" > "$tmp" &&
    mv -f "$tmp" "$G_STATE/restore.state"
}

guard_backup() {
  local hash copy_hash
  hash=$(guard_hash "$G_ACTIVE_PATH") || return 1
  case "$hash" in ''|*[!0-9a-f]*) guard_error '無法取得更新檔雜湊。'; return 1 ;; esac
  [ "${#hash}" = 64 ] || return 1
  [ ! -L "$G_STATE/backups" ] || return 1
  mkdir -p "$G_STATE/backups" || return 1
  R_BACKUP=$(mktemp -d "$G_STATE/backups/$G_BOOT-$G_ACTIVE_VERSION.XXXXXXXX") || return 1
  cp -p "$G_ACTIVE_PATH" "$R_BACKUP/artifact.apex" || { guard_error '備份失敗。'; return 1; }
  copy_hash=$(guard_hash "$R_BACKUP/artifact.apex") || return 1
  [ "$hash" = "$copy_hash" ] || { guard_error '備份雜湊不符。'; return 1; }
  R_HASH="$hash"
  R_ID=$(guard_identity)
  R_BOOT="$G_BOOT"
  printf '%s\n' "$R_ID" > "$R_BACKUP/identity.txt" || return 1
  stat -c '%a %u %g %s' "$G_ACTIVE_PATH" > "$R_BACKUP/metadata.txt" || return 1
  ls -lZ "$G_ACTIVE_PATH" >> "$R_BACKUP/metadata.txt" 2>/dev/null
  cp "$G_WORK/dump" "$R_BACKUP/before.dumpsys" || return 1
  printf '%s\n' "$R_HASH" > "$R_BACKUP/sha256.txt" || return 1
  timeout 15 sync || { guard_error '無法確認備份已寫入。'; return 1; }
  guard_log "[備份] $R_BACKUP hash=$R_HASH"
}

guard_factory_path_matches() {
  local old="$1" root allowed=0 file expected actual rc=0
  [ "$G_ART_STATE" = factory ] || { guard_error '目前不是系統確認的內建 ART。'; return 1; }
  [ "$G_FACTORY_PATH" != "$old" ] || return 0
  [ "$G_ACTIVE_PATH" = "$G_FACTORY_PATH" ] &&
    [ "${G_FACTORY_PATH%/*}" = "$G_DECOMPRESSED_ROOT" ] || {
    guard_error '內建 ART 路徑變更不是已知的解壓轉換。'; return 1
  }
  case "${G_FACTORY_PATH##*/}" in
    "com.android.art@$G_FACTORY_VERSION.decompressed.apex"|"com.google.android.art@$G_FACTORY_VERSION.decompressed.apex") ;;
    *) guard_error '還原後內建 ART 解壓檔名與版本不符。'; return 1 ;;
  esac
  for root in $G_FACTORY_ROOTS; do
    [ "${old%/*}" != "$root" ] || allowed=1
  done
  [ "$allowed" = 1 ] || { guard_error '原廠壓縮來源不在系統 APEX 目錄。'; return 1; }
  case "${old##*/}" in
    com.android.art.capex|com.google.android.art.capex|com.android.art_compressed.apex|com.google.android.art_compressed.apex) ;;
    *) guard_error '無法確認原廠壓縮 ART 來源檔名。'; return 1 ;;
  esac
  for file in "$old" "$G_FACTORY_PATH"; do
    [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] && [ "$(readlink -f "$file")" = "$file" ] || {
      guard_error '原廠 ART 來源或解壓檔不可讀，或路徑有歧義。'; return 1
    }
  done
  expected=$(guard_hash "$G_FACTORY_PATH") || return 1
  guard_prepare_work || return 1
  # Factory paths can switch from a compressed system file to its extracted
  # payload after uninstall. Compare the payload, never just the two names.
  timeout 30 unzip -p "$old" original_apex > "$G_WORK/factory-payload.apex" 2> "$G_WORK/factory-error" || rc=$?
  if [ "$rc" = 0 ]; then
    actual=$(guard_hash "$G_WORK/factory-payload.apex") || rc=1
  fi
  rm -f "$G_WORK/factory-payload.apex" "$G_WORK/factory-error"
  [ "$rc" = 0 ] || { guard_error '原廠壓縮 ART 內容讀取失敗或逾時，尚未確認還原。'; return 1; }
  [ "$actual" = "$expected" ] || { guard_error '原廠壓縮與解壓 ART 內容不一致，尚未確認還原。'; return 1; }
  guard_log '[還原驗證] 原廠壓縮映像與目前解壓 ART 的內容雜湊一致。'
}

guard_verify_restore() {
  local old_pkg old_ver old_path old_factory_ver old_factory_path
  guard_load_restore || { guard_error '解除紀錄損壞，停止處理。'; return 1; }
  case "$R_STATUS" in
    requested|pending_reboot|fallback_requested)
      if [ "$R_BOOT" = "$G_BOOT" ]; then
        guard_description '[等待重啟] 已提出解除或備援操作；本次開機不再處理。'
        return 2
      fi
      if [ "$G_ART_STATE" = factory ]; then
        IFS='|' read -r old_pkg old_ver old_path old_factory_ver old_factory_path <<EOF
$R_ID
EOF
        if [ "$G_PACKAGE" != "$old_pkg" ] || [ "$G_FACTORY_VERSION" != "$old_factory_ver" ]; then
          guard_error 'ROM/內建 ART 已變更，不能確認這次解除結果。'
          return 1
        fi
        guard_factory_path_matches "$old_factory_path" || return 1
        guard_save_restore restored || return 1
        guard_log "[還原完成] 本次開機 ART 為內建版 $G_ACTIVE_VERSION。"
      elif [ "$(guard_identity)" = "$R_ID" ]; then
        if [ "$R_STATUS" = pending_reboot ]; then
          guard_save_restore verify_failed || return 1
          guard_error '重開機後仍是原更新版；停止自動重試，請查看 Action。'
        else
          guard_save_restore blocked || return 1
          guard_error '上次操作中斷，無法確認指令結果；不開放直接刪檔。'
        fi
        return 1
      else
        guard_error '重開機後 ART/ROM 與解除紀錄不同，需人工檢查。'
        return 1
      fi
      ;;
  esac
}

guard_restore() {
  local identity result rc
  guard_allowed && guard_target || return 1
  identity=$(guard_identity)
  guard_load_restore || { guard_error '解除紀錄損壞。'; return 1; }
  if [ "$R_ID" = "$identity" ] && [ -n "$R_STATUS" ] && [ "$R_STATUS" != restored ]; then
    guard_error "這個 ART 版本已處理過（$R_STATUS），不重複解除。"
    return 1
  fi
  guard_backup || return 1
  # Refresh after copying: never uninstall a different target if a transaction
  # appeared while making the backup.
  guard_scan && guard_allowed && guard_target || return 1
  [ "$(guard_identity)" = "$R_ID" ] && [ "$(guard_hash "$G_ACTIVE_PATH")" = "$R_HASH" ] || {
    guard_error '備份期間 ART 已改變。'; return 1;
  }
  guard_save_restore requested && timeout 15 sync || return 1
  rc=0
  result=$(guard_command uninstall --versionCode "$G_ACTIVE_VERSION" "$G_PACKAGE" 2>&1) || rc=$?
  printf '%s\n' "$result" > "$R_BACKUP/uninstall.txt"
  guard_log "[解除回應] rc=$rc $result"
  if [ "$rc" = 0 ] && printf '%s\n' "$result" | grep -qx 'Success'; then
    guard_save_restore pending_reboot || return 1
    guard_description '[等待重啟] 系統已接受 ART 解除更新，請手動重開機後驗證。'
    return 0
  fi
  # Only a definitive framework uninstall failure can unlock manual fallback.
  # Timeouts, permission errors, and ambiguous responses remain blocked.
  if [ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$rc" != 137 ] &&
     printf '%s\n' "$result" | grep -q 'Failed to uninstall apex ' &&
     ! printf '%s\n' "$result" | grep -qiE 'pre.?installed|permission|SecurityException|version.*(equal|match)'; then
    guard_save_restore failed || return 1
    guard_error '系統解除更新明確失敗；可從 Action 檢查手動備援資格。'
  else
    guard_save_restore blocked || return 1
    guard_error '解除結果不明或不允許；不自動升級成刪檔。'
  fi
}

guard_fallback_eligible() {
  guard_allowed && guard_target && guard_load_restore || return 1
  case "$R_STATUS" in failed|verify_failed) ;; *) guard_error '沒有符合條件的系統解除失敗紀錄。'; return 1 ;; esac
  [ "$(guard_identity)" = "$R_ID" ] || { guard_error 'ART 與失敗紀錄不符。'; return 1; }
  case "$R_BACKUP" in "$G_STATE/backups/"*) ;; *) guard_error '備份路徑不正確。'; return 1 ;; esac
  [ -d "$R_BACKUP" ] && [ ! -L "$R_BACKUP" ] && [ "$(readlink -f "$R_BACKUP")" = "$R_BACKUP" ] || return 1
  [ -f "$R_BACKUP/artifact.apex" ] && [ ! -L "$R_BACKUP/artifact.apex" ] || return 1
  [ "$(guard_hash "$R_BACKUP/artifact.apex")" = "$R_HASH" ] &&
    [ "$(guard_hash "$G_ACTIVE_PATH")" = "$R_HASH" ] || { guard_error '目標或備份雜湊不同。'; return 1; }
}

guard_cycle() {
  local rc
  guard_stats_update || guard_log '[紀錄警告] 無法更新本次開機統計，不影響 ART 保護流程。'
  guard_scan || { guard_scan_failure_description; return 1; }
  guard_report
  if guard_paused; then guard_description '[已暫停] 不會取消或移除 ART 更新'; return 0; fi
  if guard_conflicts; then guard_description "[衝突] $G_ERROR"; return 1; fi
  if guard_monitor_only; then guard_description '[僅觀察] 會檢查狀態，但不會取消或移除更新'; return 0; fi
  guard_load_restore || { guard_description '[錯誤] 解除紀錄損壞，停止處理。'; return 1; }
  # Even while a prior uninstall waits for reboot, cancel new update trains.
  if [ -n "$G_PENDING" ]; then
    guard_cancel_pending || { guard_description "[尚未確認攔截成功] $G_ERROR"; return 1; }
  fi
  rc=0
  guard_verify_restore || rc=$?
  [ "$rc" != 2 ] || return 0
  [ "$rc" = 0 ] || { guard_description "[錯誤] $G_ERROR"; return 1; }
  if [ "$G_ART_STATE" = updated ]; then
    if [ -f "$G_MODULE/disable_auto_restore" ]; then
      guard_description '[偵測到已套用更新] 自動還原已關閉，仍會攔截後續更新'
      return 0
    fi
    guard_restore || { guard_description "[還原未完成] $G_ERROR"; return 1; }
  elif [ -n "$G_PENDING" ]; then
    guard_description '[偵測到待套用更新] 下一輪將繼續嘗試攔截 ART 更新'
  elif [ "$G_ART_STATE" = same_version ]; then
    guard_description '[監控中] ART 與出廠同版本，保留目前副本，不自動解除'
  else
    guard_description '[監控中] ART 使用出廠版本，目前沒有待套用的 ART 更新'
  fi
}
