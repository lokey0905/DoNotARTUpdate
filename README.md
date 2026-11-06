# Do Not ART Update

Magisk / KernelSU / APatch 模組，目標是降低 ART Mainline 更新造成 LSPosed、Zygisk 或其他 runtime hook 不相容的風險。

> [!CAUTION]
> `v2.2.0-test2` 是實驗分支。Samsung A55 / Android 14 已驗證待更新攔截、重開機自啟動、一般 Action 顯示，以及 ART 372042720 經系統解除後回復原廠 341411300；手動刪檔及其他機型仍未完成實機驗證。
> 預設會取消包含 ART 的更新交易，並在檢查通過後嘗試解除已套用的 ART 更新。
> 取消父交易也會取消同批其他 Mainline 更新，包含安全修補；還原 ART 不保證修復所有 hook 問題，也可能造成 bootloop。
> 安裝前應備份資料，並確認 recovery 救援方式。不建議直接部署到唯一的日用手機。

> [!CAUTION]
> 不可併用 ART 降版／移除模組。已知衝突為 `zwajton/ART-downgrade`（`ART_Uninstall`）與 `ART_fix`。
> 同時檢查 `/data/adb/modules` 與 `/data/adb/modules_update`，啟用中的衝突模組會阻止操作。
> 停用第三方模組不會撤銷它已造成的變更；請先移除並重開機。

## 處理架構

| 狀態 | 處理方式 |
|---|---|
| 1. Active 為內建 ART，無待處理 ART 交易 | 持續監控 |
| 2. ART staged 交易尚未就緒 | 辨識父子關係後提出取消，不誤報為等待重開機 |
| 2. ART staged 交易已 ready | 取消父交易，重新查詢確認結果 |
| 3. 已套用非內建、不同版本 ART | 確認系統穩定、內建檔可用及無未完成交易後，備份並透過系統解除更新 |
| Active 是與出廠同版本的資料分區副本 | 保留副本，不自動解除或提供刪檔備援；仍攔截後續待更新交易 |
| 3+2. 已套用且另有待更新 | 先處理待更新交易，再評估目前更新版 |
| 已接受解除／手動備援 | 記錄等待重開機，同一開機期間不再操作 |
| 重開機後 | 比對實際 Active / Factory 狀態，確認還原或回報失敗 |
| 查詢錯誤、缺欄位、未知格式 | 停止寫入並顯示錯誤，不當成「沒有更新」 |

### 監控與取消

- 每 30 秒查詢 ready parent IDs；每 10 輪進行完整查詢。查詢失敗則提早完整查詢。
- ID 快速查詢只用來安排掃描時機，不能拿空輸出證明沒有更新。
- 完整查詢只取一次 `dumpsys package` 快照，共用解析 Active / Factory 與 PackageInstaller 交易。
- 支援 `mStagedSession*` 與 `mSession*` 狀態欄位；檢查必要布林值、父子連結、非 ART 交易及歷史父交易。
- 取消指令成功不等於取消完成。重新查詢三次，未確認則保留異常狀態；同一開機、同一 session 最多提出三次請求。
- 安裝時立即執行一次完整處理，避免已有 ready 更新直到下次啟動服務才被發現。
- 持續背景監控在下次開機啟動；安裝完成到重開機之前仍有新交易進入的空窗。

這仍是盡力攔截：輪詢與重開機有競態，無法保證百分之百阻擋，也不阻止下載或 ROM OTA 更新。

系統回復可能把原版本 ART 放回 `/data/apex/active`，此時 `IsFactory=false`，但版本已與出廠相同。
模組會顯示「同版本副本」，不為清理路徑而再解除。版本相同不代表內容雜湊相同，也不直接當成先前解除已驗證成功。

### 系統解除更新

解除前必須確認 Android 12+、可更新 APEX、開機完成、Active 明確為非內建且不同版本、目標是預期的 ART 更新檔，且 Factory 檔案可讀。
支援系統分割區內的標準 `.apex`／`.capex` 與三星 `com.android.art_compressed.apex`／`com.google.android.art_compressed.apex` 精確檔名，不放寬為任意萬用字元。
Factory 若指向 decompressed ART，另須確認對應的系統分割區 `.capex` 來源；decompressed 檔案只讀取，不移除。
此外，PackageInstaller 必須沒有未完成的 staged 交易，apexd 也必須能確認沒有正在啟用／回滾的交易。
若 ROM 沒有提供支援的 apexd 狀態輸出，只監控，不猜測後強制解除。

先備份更新檔、SHA-256、權限資訊及查詢快照，再以確切的套件與版本呼叫系統解除介面。
解除意圖在呼叫前持久化，避免腳本中斷後重複操作。成功後只標記「等待重開機」，不立即再判定版本是否下降。
等待重開機期間仍會取消新進來的 ART 交易，避免下一次開機又套用更新。
逾時、權限錯誤、含糊回應均不會自動轉為刪檔。

解除後 Factory 路徑可能由系統壓縮容器變成 `/data/apex/decompressed` 下的解壓映像。
套件與原廠版本必須一致，且系統須確認目前為內建 ART；這種路徑轉換另外核對壓縮容器內 `original_apex` 與目前解壓檔的 SHA-256。
來源不明、內容不符、解壓失敗或逾時都不會標記還原成功；不以同版本或檔名相似取代內容驗證。

### Action 最後備援

Action 先顯示 ART 狀態、目前／出廠版本、本次開機成功取消次數與最後成功取消時間。
它不會主動取消待更新交易，也不會主動呼叫系統解除更新；這兩項由背景服務處理。
只有存在對應 ART 的明確解除失敗，或重開機後仍未還原的紀錄時，才提供備援。

1. 檢查目前 ART、Factory、交易狀態、原目標與備份雜湊。
2. 顯示套件、版本、完整目標路徑、備份路徑與解除回應。
3. 要求兩次獨立音量鍵確認：音量上放開確認，音量下取消，每次 30 秒逾時自動取消。
4. 確認後重新查詢，若狀態、檔案或停用旗標改變就停止。
5. 只移除指定的 ART 更新檔，標記等待重開機；不自動重開機。

`getevent` 不可用、無法取得按鍵或缺少可信備份時，不提供免確認的替代入口。
背景服務、安裝程式、Action 共用操作鎖。鎖不能阻止 Google 安裝者在外部修改狀態，因此備援仍不是無風險操作。

## 永不自動執行

- 清空 `/data/apex/active` 或任何 APEX session 目錄。
- 刪除其他模組、Factory、decompressed 或掛載目錄。
- 系統解除失敗後由背景服務直接刪檔。
- 自動重開機、格式化資料、重複重開機修復。
- 透過停用 modulemetadata 或修改 `ro.apex.updatable` 阻擋更新。

## 開關

在模組目錄 `/data/adb/modules/DoNotARTUpdate/` 建立以下空檔案即可生效：

| 檔案 | 作用 |
|---|---|
| `monitor_only` | 只觀察，不取消交易、不解除、不允許 Action 移除 |
| `disable_session_guard` | 暫停整個處理流程，含第一次掃描的寫入與 Action 備援 |
| `disable_auto_restore` | 仍取消待套用交易，但不自動解除已套用更新 |

管理器的 `disable` / `remove` 旗標也會阻止已在執行的腳本繼續寫入。
升級時保留上述三個偏好檔。舊測試版的 `enable_session_abandon` 已不需要，**新測試版預設為啟用處理**；要保留舊版只觀察行為，升級前先建立 `monitor_only`。

## 紀錄與備份

模組列表的 `module.prop` → `description` 會使用「監控中」「僅觀察」「已暫停」「還原未完成」等狀態，並附上成功取消次數與時間，例如：

```text
[監控中] ART 使用出廠版本，目前沒有待套用的 ART 更新；本次開機成功取消 2 次；最後成功取消：2026-11-06 10:34:59 +0800
```

次數與時間皆只屬於本次開機：重開機後歸零／清空。只有取消指令成功、重新查詢確認交易已離開待處理清單，且執行中的 ART 未改變時才記錄；重試、未確認、解除更新與手動救援都不計入。
時間採裝置時區，不會被例行掃描覆蓋。統計從此功能啟用後開始，不回填舊的取消嘗試紀錄；同一筆交易只計一次。

資料保留在 `/data/adb/DoNotARTUpdate/`，不在會被模組升級／解除安裝刪除的目錄內：

- `guard.log` / `guard.log.old`：各約 256 KiB 的輪替紀錄。
- `restore.state`：解除／備援的目標、boot ID、備份與進度；以資料讀取，不當成 shell 執行。
- `backups/`：更新檔、原路徑、SHA-256、權限資訊、操作前 dumpsys、解除回應。
- `cancel-<boot>-<id>`：當次開機取消請求次數。
- `interceptions.state`：本次開機已確認成功的交易與時間；原子寫入，換開機 ID 後清除舊統計。損壞時顯示無法讀取，不阻止 ART 保護流程。
- `lock-<boot-id>`：互斥鎖。正常退出會釋放；同次開機的中斷鎖不會被強制搶走。

若操作遭強制中止，先檢查紀錄。下次開機使用新的鎖，但仍會讀取解除紀錄判斷結果，不直接重做。
備份與歷史紀錄不自動清除，需自行管理空間。備份不等於保證能恢復開機；救援時還需正確權限、SELinux 標籤與一致的系統狀態。

## 唯讀檢查

```sh
sh /data/adb/modules/DoNotARTUpdate/service.sh --check-state
sh /data/adb/modules/DoNotARTUpdate/service.sh --check-sessions
sh /data/adb/modules/DoNotARTUpdate/service.sh --status
```

這三個模式不執行取消、解除、備援或更新模組描述；只建立短期查詢暫存檔。`--status` 是較易閱讀的狀態與統計摘要。
`--once` 是會修改系統的單次處理入口，不是診斷用指令。

## 開發驗證

在 Linux 或 Windows Git Bash 執行：

```sh
bash tests/test-session-parser.sh
bash tests/test-guard.sh
```

第二組測試的 PackageManager、boot ID、Android 屬性與按鍵確認均由 mock 提供；檔案操作只發生在新建的隔離目錄。
通過不代表已驗證實機套用、回復、按鍵輸入或重開機相容性。正式發布前仍需在可救援的測試機上驗證三種狀態及失敗路徑。

## 線上更新與版本

此分支模組版本為 `v2.2.0-test2` / `versionCode=221`。
穩定頻道的 `update.json` 保持 `2.1.2`，不把未完成實機驗證的測試版推送到正式更新頻道。
打包時必須包含 `lib/`；它是所有入口共用的必要程式。

## 設計依據

- [AOSP PackageInstallerSession](https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/pm/PackageInstallerSession.java)：父交易取消與狀態。
- [AOSP ApexManager](https://android.googlesource.com/platform/frameworks/base/+/26b017aae2129dddee9fff881a22cf3813291eef/services/core/java/com/android/server/pm/ApexManager.java)：系統解除更新入口。
- [AOSP apexd](https://android.googlesource.com/platform/system/apex/+/refs/heads/android16-s2-release/apexd/apexd.cpp)：解除檔案與內建 APEX 檢查。

Original idea: [dyrok/disable-gpsu-bootloops](https://github.com/dyrok/disable-gpsu-bootloops)。Modified by `lokey0905`。
