# Changelog

## Unreleased

- 修正 NOTHING Android 16 安裝預檢：明確尚未提交且未就緒、套件名稱為 null 的交易保留追蹤，不再阻擋其他已辨識 ART 交易的取消。
- 未辨識交易仍計入忙碌狀態並阻止 ART 解除，細節僅保留於診斷 log，不顯示於模組描述及 Action／狀態摘要；已提交、已就緒、欄位缺失或父子關係錯誤仍停止處理。
- 114 項隔離測試通過；NOTHING A142 實測安裝時取消一批 ART 更新，保留未辨識交易與其他三批非 ART 更新。重啟後確認原廠 ART 未變更、背景監控持續執行且取消統計按開機重置。

## 2.2.0

### 監控與取消

- 預設監控取消 ART 交易；增加 monitor_only 與 disable_auto_restore 開關。
- 共用嚴格解析器，支援新舊 session 欄位、驗證父子連結，查詢失敗不再當成沒有更新。
- 取消後重新查詢確認，限制同一 session 的重試次數。
- 安裝時先處理既有交易；等待解除重開機期間仍會取消新進來的 ART 更新。

### 系統解除與手動備援

- 已套用更新先備份，透過限定版本的系統解除介面處理；持久化等待重啟與驗證結果。
- 修正解除後 Factory 從壓縮容器切換為解壓映像時的誤判；核對 `original_apex` 內容雜湊後才確認還原，保留來源、版本與讀取失敗防護。
- 最後刪檔備援僅在 Action 通過前置檢查、備份雜湊比對及兩次按鍵確認後執行。
- 安裝、服務與 Action 共用操作鎖；停用旗標與衝突檢查涵蓋寫入入口。
- 開機早期不處理 APEX；背景服務不直接刪 ART 或 sessions，也不自動重開機。

### 相容性修正

- 修正 Note20 大型 Mainline 交易的子 ID 清單換行解析，包含數字中途折行；保留分隔符、重複 ID、截斷與父子關係驗證。
- 支援三星內建 ART 的 `_compressed.apex` 精確檔名；維持系統目錄、路徑、版本與交易安全檢查。
- 保留與出廠同版本的資料分區 ART 副本，不自動解除或提供刪檔備援，但仍攔截後續更新。版本相同不當成還原內容驗證成功。
- 支援三星 Active Session / Active Child Session 與 Finalized session 區段，維持父子連結驗證與非 ART 交易排除。
- 明確設定 dumpsys 逾時並拒絕 stdout 內的逾時輸出。
- 修正 Kitsune Action 繼承不存在的 TMPDIR 時只顯示「停止」：改用可用暫存路徑，並補齊初始化失敗原因。

### 狀態與統計

- 模組列表與 Action 改用易讀狀態，顯示本次開機成功取消次數與最後成功取消時間；兩者重開機後重置，只記錄已確認成功的取消。
- 新增唯讀 `service.sh --status` 摘要；成功統計採原子儲存，同筆交易去重，統計讀寫失敗不阻止原有 ART 保護。

### 驗證範圍

- 98 項隔離回歸測試通過，涵蓋交易解析、取消、解除、還原驗證、統計與手動備援防護。
- Samsung A55 已驗證待更新攔截、重開機、一般 Action 與已套用 ART 的系統解除回復；Note20 已驗證大型多套件交易解析與 ART 待更新攔截，其他三批非 ART 交易保留。
- 使用者回報三台裝置測試未發現問題；手動刪檔備援與其他 ROM 仍需獨立驗證。
- 正式版本為 `v2.2.0` / `versionCode=222`；更新 GitHub Release 與線上更新資訊，支援從 2.1.2 及先前測試版升級。

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
