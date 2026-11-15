# DEA-479 客户端自更新（首批 Windows + Android）

本文件记录 Muse 负责的客户端部分：设置页更新界面、进程根更新控制器接线、草稿/在途
安装安全门、Release 正文安全链接，以及 Android 系统安装适配与跨进程结果恢复。

共享更新契约 `client/lib/updates/update_contract.dart`（Release 选择、检查时机、固定
资产下载、校验和、安装入口）由 Forge 维护，是唯一状态来源；本文件描述的界面只消费
契约快照并发起用户明确要求的动作，不自行实现版本比较、下载或校验。

## 落地范围

| 文件 | 作用 |
|---|---|
| `lib/ui/updates/update_scope.dart` | 进程根更新栈：每进程一个 `ReleaseUpdateController`，启动时一次 `checkOnce()`，Android 先恢复上次安装事务；不支持的平台不构造更新器 |
| `lib/ui/updates/update_settings_host.dart` | 契约 → 界面映射与回调：检查/下载/安装/取消/重试/权限设置/重新打开安装器/安全链接确认 |
| `lib/ui/updates/update_ui_mapper.dart` | `UpdateSnapshot` + 安全门 + 跨进程恢复 → `UpdateUiState` 的唯一映射点 |
| `lib/ui/updates/update_settings_page.dart` | “设置 → 软件更新”页面：状态展示与用户动作，不直接发起网络或安装 |
| `lib/ui/updates/update_ui_state.dart` | 仅供展示的只读快照与阶段枚举 |
| `lib/ui/updates/release_notes_view.dart` | Release 正文的安全 Markdown 呈现（不执行 HTML、不加载远程图片；链接需点击并确认后才显式打开） |
| `lib/ui/updates/update_link_opener.dart` | 桌面默认浏览器打开；Android 走更新通道的 `openExternalUrl` |
| `lib/ui/chat/chat_drafts.dart` | 进程内未发送草稿/待发媒体存储，路由销毁不清除；同时注册 `InstallSafetyGate` 阻塞 |
| `lib/updates/android_update_installer.dart` | Android 的 `UpdateInstaller` 实现：实际版本/ABI、提交 APK 前重算哈希、安装事务标记与恢复 |
| `android/app/src/main/kotlin/ai/bb/bb_mobile/UpdateInstaller.kt` | 原生侧：安装前校验、FileProvider 授权、系统安装 Intent、结果回传、https 链接打开 |
| `android/app/src/main/res/xml/update_paths.xml` | FileProvider 仅暴露应用私有 cache/files 目录 |

## 进程根与导航

- `main.dart` 用 `UpdateScope` 包住 `BbRoot`，在认证/服务器地址服务之外创建唯一
  `ReleaseUpdateController`；登录切换、服务器设置、Profile 面板开关都不会新建第二个
  控制器或重复检查。启动检查不 await，不阻塞首帧、登录恢复或消息。
- 非 Windows/Android 平台不构造更新器；设置页显示“当前平台暂不支持应用内更新”。
- Profile 面板新增“设置”入口；面板以结果关闭后由首页路由到更新页，避免把设置页叠在
  对话框后面。
- 阶段映射：`contract current → upToDate`、`available → available`、`ready → ready`
  （已下载并通过校验，安装按钮独立）、`installerOpened → installing`、
  `permissionRequired → permissionRequired`、`cancelled/failed → failed`。
- 下载与安装是两个显式动作：`available` 只提供“下载更新”，`ready` 才提供“安装更新”；
  重试规则是“没有固定 Release 时重试检查，有固定 Release 时重试下载”，不会悄悄换成
  另一个 Release。

## 草稿、在途操作与安装安全门

- 未发送文字、待发图片/附件写入 `ChatDrafts`（按当前 `ChatService` 会话隔离）；离开
  聊天页只保存当前草稿并**不清除**，重新进入聊天会恢复。显式发送或清空才解除。
- 每次草稿写入同步 `InstallSafetyGate.instance.setBlocker(owner, reason)`；更新页在
  `ready` 阶段发现阻塞时显示 `blocked` 与具体原因，不显示安装入口。安装进行中聊天输入
  被禁用（`IgnorePointer`），避免产生新草稿。
- 发送/上传本身由 Forge 的 `InstallSafetyGate.protect` 包装；服务栈销毁（切换服务器/
  退出登录）时清理该会话草稿，路由销毁不做清理。
- 失败待重发气泡仍是既有聊天状态，不因更新需求扩成通用草稿持久化重构；安装期间它不会
  被更新流程丢弃。

## Release 正文与链接

- HTML/脚本只作为字面文字显示；不加载远程图片（`![x](...)` 只显示替代文字）。
- 只有 `http(s)` 目标渲染为链接；其他 scheme 保持原文。链接默认无手势，接入 host 后
  点击会弹出确认框展示完整 URL，用户确认后才在浏览器打开（Android 原生再校验 https）。

## Android 安装与跨进程恢复

1. `platformInfo()` 读取系统实际安装的 versionName/versionCode 与受支持 ABI；无受支持
   ABI 或读不到版本时明确报错，不伪造可更新状态。
2. `install(VerifiedUpdate)` 校验文件名/长度，并重新计算 SHA-256 后才写入安装事务标记
   （cache 目录 `dea479-pending-install.json`）。原生再做包名、versionCode 递增、签名
   连续性、ABI 与私有路径校验，然后经 FileProvider 交给系统安装器。
3. 系统返回 `launched` 报 `installerOpened`；缺少“安装未知应用”权限时删除事务并报
   `permissionRequired`，用户授权后显式重试；被拒绝时抛出可读原因且不打开安装器。
4. 安装会替换进程。下次启动时 `recoverPendingInstall()` 比较已安装版本与事务目标：
   达到目标则报告 `installed`，否则报告“上次安装未完成”，两种情况都删除事务与暂存包，
   不会假装成功或重新自动安装。用户在设置页看到一次性提示，任何检查/重试动作清除它。

## 验证

```bash
# 客户端全量（本机 Linux，Flutter 3.47.9 / Dart 3.13.7）
flutter analyze                       # No issues found
flutter test                          # 620 passed, 9 skipped
# 本轮新增/更新回归：
#   test/update_settings_wiring_test.dart      启动一次、下载/安装分离、重试、安全门、恢复、链接确认、不支持平台
#   test/update_navigation_test.dart           Profile → 设置导航
#   test/chat_draft_install_gate_test.dart     离开聊天后草稿保留并阻止安装、清空后释放、安装中禁用编辑
#   test/android_update_adapter_test.dart      实际版本/ABI、哈希重校验、权限、拒绝、跨进程恢复、https 链接
#   test/android_update_installer_test.dart    原生通道解析与事件
# 以及更新后的 update_settings_page_test.dart / update_release_notes_test.dart
```

Android release 构建（JDK 17，本机 Android SDK）：

```bash
flutter build apk --release --target-platform android-arm64
```

构建与 APK 摘要见本轮交付回帖；APK 用仓库 debug keystore 签名，可安装、不可上架。

## NOT RUN（未测项，不冒充通过）

- **真机安装**：当前环境无 Android 设备，系统安装/取消/权限拒绝/覆盖安装、“安装未知
  应用”跳转与返回、跨进程恢复的真机行为均 **NOT RUN**（Dart/原生通道层与构建已验证）。
- **Windows 更新执行器/断电恢复**：属 Forge 范围；Windows 运行时离线，保留给固定候选验收。
- **真实浏览器打开链接**：桌面/Android 的浏览器启动未在真机/桌面会话实测，测试使用替身
  验证“确认后只打开一次、取消不打开”。
