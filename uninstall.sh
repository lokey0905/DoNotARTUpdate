#!/system/bin/sh

# 恢復 overlay modulemetadata
pm enable --user 0 com.google.android.overlay.modules.modulemetadata.forframework 2>/dev/null

# 確保主 modulemetadata 存在並啟用
pm install-existing --user 0 com.google.android.modulemetadata 2>/dev/null
pm enable --user 0 com.google.android.modulemetadata 2>/dev/null