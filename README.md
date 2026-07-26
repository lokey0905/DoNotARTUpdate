# Do Not ART Update

基於 [`dyrok/disable-gpsu-bootloops`](https://github.com/dyrok/disable-gpsu-bootloops) 修改的 Magisk / KernelSU / APatch 模組，用於降低 Google Play System Update 更新 ART APEX 後導致 hook、Zygisk、Frida 或 runtime patch 失效的風險。

> ⚠️ 這是進階系統修改工具。請先確認你具備 recovery / fastboot / factory image 救援能力；錯誤操作可能造成 bootloop。

> [!CAUTION]
> DoNotARTUpdate 不可與其他 ART 降版、移除或卸載模組同時使用。
>
> 已知衝突：
>
> - [`zwajton/ART-downgrade`](https://github.com/zwajton/ART-downgrade)（模組 ID：`ART_Uninstall`）
> - `ART_fix`（模組 ID：`ART_fix`）
>
> 同時使用可能造成 APEX staged session 與實際 ART 檔案狀態不一致，導致 zygote crash 或 bootloop。安裝程式會拒絕併裝；若衝突模組是在之後安裝，session guard 會停止處理。

## 目前策略

`v2.2.0-test1` 採用 **PackageInstaller staged session guard**：

- 等待 `PackageManager` 可用後，每 30 秒查詢 ready parent sessions
- 每 5 分鐘完整解析一次 staged session 記錄
- 從 PackageInstaller session 記錄識別：
  - `com.android.art`
  - `com.google.android.art`
- 如果 ART 是 multi-package Mainline train 的 child session，定位並處理父層 session
- 測試版預設為 `monitor-only`
- 建立 `enable_session_abandon` marker 後，才使用 `cmd package install-abandon <parentSessionId>`
- 保留 `com.google.android.modulemetadata` 主套件
- 不再直接刪除 `/data/apex/sessions`、`/metadata/apex/sessions` 或 `/data/apex/active`

取消父層 Mainline train 會同時取消該 train 內的其他模組，不是只移除 ART child session。

## 三種狀態

| 狀態 | 判斷條件 | 處理 |
|---|---|---|
| 狀態 1：ART 未更新 | Active 是 Factory，且沒有未終止的 ART staged session | 保持監控 |
| 狀態 2：等待重開機套用 | ART parent session 為 `applied=false`、`failed=false`、`destroyed=false`；`ready=true` 代表已可在下次重開機套用 | monitor-only 記錄；啟用 abandon 後取消父層 train |
| 狀態 3：已安裝 ART 更新 | Active `IsFactory=false`，或 Active 版本高於 Factory | 不直接刪除 active APEX，只警告並繼續攔截後續更新 |

`applied=true` 的歷史 ART session 不會單獨觸發狀態 3；仍以目前 Active / Factory APEX 為準。狀態 3 之後若又出現新 pending train，description 會顯示 `狀態3+2`。

## 功能

- 安裝時與開機後檢查 ART Active / Factory 版本
- 支援 `com.google.android.art` 與 `com.android.art` 兩種 ART APEX 包名
- 持續偵測包含 ART 的 PackageInstaller staged train
- 提供 monitor-only 與明確啟用的 session abandon 模式
- 支援三星 compressed / decompressed ART 狀態
- 安裝與開機時偵測 `ART_Uninstall`、`ART_fix` 衝突模組並停止處理
- 支援 Magisk App 透過 `updateJson` 檢查及下載線上更新
- 透過 `module.prop` description 顯示狀態，例如：

```text
[狀態1] ART 未更新。Active=331813010 Factory=331813010。
[狀態2] ART 更新已就緒，等待重開機套用。Session=123456。
[狀態3] 已安裝新版 ART。Active=361501120 Factory=331813010。
[狀態3+2] 已安裝新版 ART，另有待套用更新。Session=123456 Ready=true。
[略過] Android 11/API 30 低於 Android 12，不處理 ART。
[錯誤] Android 13/API 33 未檢測到 ART APEX，請檢查 ROM dumpsys。
```

## 不做的事

- 不停用 Play Store 的 Google Play 系統更新 UI
- 不阻止 Google Play 下載 Mainline 更新
- 不停用或 uninstall `com.google.android.modulemetadata`
- 不直接刪除 active、factory、mounted、decompressed APEX
- 不直接刪除 apexd 或 PackageInstaller session 檔案
- 不自動回復已經啟用的新版 ART
- 不自動重開機
- 不保證所有 Android 版本與 ROM 都能完全阻止 ART 更新

## 安裝

從 Release 下載最新模組 ZIP，之後將模組 ZIP 透過 Magisk / KernelSU / APatch 安裝，然後重開機。

## 線上更新

Magisk App 會從 [`update.json`](https://raw.githubusercontent.com/lokey0905/donnotARTUpdate/main/update.json) 讀取最新版本、更新內容與 Release ZIP。發布新版本時，Release tag 應與版本號一致，並附加名為 `DoNotARTUpdate.zip` 的資產。

## 驗證

查看 ART Active / Factory 狀態：

```sh
for pkg in com.google.android.art com.android.art; do
  dumpsys package "$pkg" | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|Version:|versionCode|IsActive|IsFactory|sourceDir'
done
```

安全狀態通常是：

```text
Active version == Factory version
```

查看 staged sessions：

```sh
cmd package list staged-sessions --only-parent
cmd package list staged-sessions --only-ready --only-parent
sh /data/adb/modules/DoNotARTUpdate/service.sh --check-sessions
sh /data/adb/modules/DoNotARTUpdate/service.sh --check-state
```

查看模組 log：

```sh
cat /data/adb/modules/DoNotARTUpdate/gpsu_art_guard.log
```

## 開關檔案

| 檔案 | 說明 |
|---|---|
| `enable_session_abandon` | 取消偵測到的 ART 父層 staged train；測試版預設不存在 |
| `disable_session_guard` | 暫停 staged session 查詢與處理 |
| `art_staged_update_detected` | 狀態 2；內容為 `sessionId|ready|count` |
| `art_update_detected` | Active ART 已高於 Factory ART |

啟用 staged train 取消：

```sh
touch /data/adb/modules/DoNotARTUpdate/enable_session_abandon
```

暫停 session guard：

```sh
touch /data/adb/modules/DoNotARTUpdate/disable_session_guard
```

## 常見狀況

**Google Play 系統更新 UI 還能打開是正常的。**  
本模組不處理 UI 或下載。monitor-only 只記錄 session；abandon 模式會在重啟套用前取消包含 ART 的父層 staged train。

**已經啟用的新版 ART 不會被本測試版直接降回 factory。**
session guard 只處理尚未套用的交易，避免再次使用 raw APEX 檔案刪除造成 session 與實際檔案狀態不一致。

**`/data/apex/decompressed` 裡有 ART 不一定是更新版。**  
三星 compressed ART 回到 factory-equivalent 狀態時可能會顯示在這裡，只要 Active 與 Factory 版本相同就是正常狀態。

**Android 11 或更舊版本不支援本模組處理的 Android 12+ ART Mainline 流程。**
安裝時會拒絕 Android 12 以下版本；已安裝狀態下會顯示不支援並略過 ART 處理。

**Android 12+ 如果未檢測到 ART APEX 不是正常略過。**
模組會同時檢查 `com.google.android.art` 與 `com.android.art`。如果 Android 12+ 仍未檢測到，會顯示檢測異常，代表 ROM 的 `dumpsys package` 輸出格式或 APEX 狀態需要另外確認。

## 模組結構

```text
DoNotARTUpdate/
├── module.prop
├── update.json
├── CHANGELOG.md
├── customize.sh
├── post-fs-data.sh
├── service.sh
├── action.sh
└── uninstall.sh
```

## Credits

- Original idea / base module: [`dyrok/disable-gpsu-bootloops`](https://github.com/dyrok/disable-gpsu-bootloops)
- Modified by: `lokey0905`
