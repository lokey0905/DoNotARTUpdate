# Do Not ART Update

基於 [`dyrok/disable-gpsu-bootloops`](https://github.com/dyrok/disable-gpsu-bootloops) 修改的 Magisk / KernelSU / APatch 模組，用於降低 Google Play System Update 更新 ART APEX 後導致 hook、Zygisk、Frida 或 runtime patch 失效的風險。

> ⚠️ 這是進階系統修改工具。請先確認你具備 recovery / fastboot / factory image 救援能力；錯誤操作可能造成 bootloop。

## 目前策略

本模組採用 **Force Remove 模式**：

- 清除尚未套用的 staged APEX sessions：`/data/apex/sessions/*`
- 開機早期移除 updated ART active APEX：
  - `/data/apex/active/com.android.art@*.apex`
  - `/data/apex/active/com.google.android.art@*.apex`
- 保留 `com.google.android.modulemetadata` 主套件
- 僅嘗試停用 modulemetadata overlay：
  - `com.google.android.overlay.modules.modulemetadata.forframework`
- 不使用 `pm rollback-app`
- 不使用 `pm uninstall-system-updates`
- 不刪除 `/system/apex`、`/apex`、`/data/apex/decompressed`

## 功能

- 安裝時與開機後檢查 ART Active / Factory versionCode
- 偵測並移除 Google Play 更新後的 ART APEX
- 支援三星 compressed / decompressed ART 狀態
- 透過 `module.prop` description 顯示狀態，例如：

```text
[正常] ART 已是內建等效版本。Active=331813010 Factory=331813010。
[重啟] 已移除新版 ART，請重開機套用。Active=361501120 Factory=331813010。
[略過] 未找到 Google ART APEX。Android 11 或更舊版本通常不需要處理 ART 遠端更新。
```

## 不做的事

- 不停用 Play Store 的 Google Play 系統更新 UI
- 不停用或 uninstall `com.google.android.modulemetadata`
- 不刪除 factory / mounted / decompressed APEX
- 預設不自動重開機
- 不保證所有 Android 版本與 ROM 都能完全阻止 ART 更新

## 安裝

從 Release 下載最新模組 ZIP，之後將模組 ZIP 透過 Magisk / KernelSU / APatch 安裝，然後重開機。

## 驗證

查看 ART Active / Factory 狀態：

```sh
dumpsys package com.google.android.art | grep -iE 'Active APEX packages|Inactive APEX packages|Factory APEX packages|Path:|versionCode|sourceDir'
```

安全狀態通常是：

```text
Active versionCode == Factory versionCode
```

查看 staged sessions：

```sh
cmd package list staged-sessions
cmd package list staged-sessions | grep -i art
```

查看模組 log：

```sh
cat /data/adb/modules/DoNotARTUpdate/gpsu_art_guard.log
```

## 開關檔案

| 檔案 | 說明 |
|---|---|
| `disable_force_remove` | 只監控 ART，不自動移除 updated ART |
| `auto_reboot_after_remove` | 移除 updated ART 後自動重啟 |
| `reboot_required_after_art_remove` | 已移除 updated ART，需要重開機 |
| `unsafe_art_path_detected` | 偵測到不安全路徑，已拒絕移除 |

啟用自動重啟：

```sh
touch /data/adb/modules/DoNotARTUpdate/auto_reboot_after_remove
```

停用 Force Remove：

```sh
touch /data/adb/modules/DoNotARTUpdate/disable_force_remove
```

## 常見狀況

**Google Play 系統更新 UI 還能打開是正常的。**  
本模組不處理 UI，只處理 staged / active ART APEX。

**`/data/apex/decompressed` 裡有 ART 不一定是更新版。**  
三星 compressed ART 回到 factory-equivalent 狀態時可能會顯示在這裡，只要 Active 與 Factory versionCode 相同就是正常狀態。

**Android 11 或更舊版本可能沒有 `com.google.android.art`。**  
這通常代表該裝置沒有 Android 12+ 的 Google ART Mainline 更新機制，模組會略過 ART 處理。

## 模組結構

```text
DoNotARTUpdate/
├── module.prop
├── customize.sh
├── post-fs-data.sh
├── service.sh
├── action.sh
└── uninstall.sh
```

## Credits

- Original idea / base module: [`dyrok/disable-gpsu-bootloops`](https://github.com/dyrok/disable-gpsu-bootloops)
- Modified by: `lokey0905`
