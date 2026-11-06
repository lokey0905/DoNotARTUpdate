#!/system/bin/sh

SKIPUNZIP=0
. "$MODPATH/lib/art-guard.sh"
guard_init "$MODPATH"

ui_print '- Do Not ART Update v2.2.0'
ui_print '- 預設取消 ART 更新交易，並在檢查通過後嘗試解除已套用更新。'
ui_print '- 取消父交易也會取消同批其他 Mainline 更新；不自動重開機。'

guard_platform || abort "! $G_ERROR"
if guard_conflicts; then abort "! $G_ERROR 請移除後重開機再安裝。"; fi
[ "$BOOTMODE" = true ] || abort '! 請在已啟動的 Android 系統內安裝；recovery 無法完成交易預檢。'

for flag in monitor_only disable_session_guard disable_auto_restore; do
  if [ -f "$G_MODULES/DoNotARTUpdate/$flag" ]; then
    touch "$MODPATH/$flag" || abort '! 無法保留模組設定。'
  fi
done

set_perm_recursive "$MODPATH/lib" 0 0 0755 0644
for script in post-fs-data.sh service.sh action.sh uninstall.sh; do
  set_perm "$MODPATH/$script" 0 0 0755
done
set_perm "$MODPATH/module.prop" 0 0 0644

# Inspect before recommending a reboot: apexd can activate a ready update
# before this module's first service invocation.
if ! guard_lock; then
  guard_cleanup
  abort "! $G_ERROR 請待其他操作結束後再安裝。"
fi
if ! guard_scan; then
  install_error="$G_ERROR"
  guard_cleanup
  abort "! $install_error"
fi
install_rc=0
guard_cycle || install_rc=$?
install_error="$G_ERROR"
guard_cleanup
if [ "$install_rc" != 0 ]; then
  ui_print "! 安裝完成，但保護流程未完成：$install_error"
  ui_print '! 不代表已阻擋更新；請先查看 Action/診斷紀錄，再決定是否重開機。'
fi
ui_print '- 持續監控於下次開機啟動；安裝後至重開機前沒有新背景監控程序。'
ui_print '- 最後刪檔備援只在 Action 通過檢查並兩次確認後執行。'
ui_print '- 紀錄與備份：/data/adb/DoNotARTUpdate（移除模組時仍保留）。'
