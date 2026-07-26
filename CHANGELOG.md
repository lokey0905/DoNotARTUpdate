# Changelog

## 2.2.0-test1

- 以 PackageInstaller staged session guard 取代 raw APEX 檔案與 session 目錄刪除。
- 每 30 秒查詢 ready parent session，並每 5 分鐘完整掃描包含 ART 的 Mainline train。
- 測試版預設為 monitor-only；建立 `enable_session_abandon` 後才會取消父層 train。
- 不再停用 modulemetadata overlay，並等待 PackageManager 實際可用後再查詢。
- 新增 ART 未更新、等待重開機套用、已安裝更新三態判斷，歷史 applied session 不會誤判目前 Active 狀態。

## 2.1.2

- 安裝時拒絕與 `ART_Uninstall`、`ART_fix` 同時啟用。
- 開機時若偵測到衝突模組，在任何 APEX session 清理或 ART 移除前停止處理。
- 新增 Magisk `updateJson` 線上更新支援。
