# DEA-479 客户端自更新（首批 Windows + Android）

本文件记录 Muse 负责的客户端部分：设置页更新界面外壳与 Android 系统安装接入。
共享更新契约 `client/lib/updates/update_contract.dart`（版本选择、检查时机、下载队列、
校验和、安装安全门）由 Forge 维护，是唯一状态来源；本文描述的界面只消费契约映射出的
只读快照，不自行发请求、不写文件、不启动安装。

## 当前落地范围（本轮）

| 文件 | 作用 |
|---|---|
| `lib/ui/updates/update_settings_page.dart` | “设置 → 软件更新”页面外壳：手动检查、版本号、原始 Release 正文、下载进度/取消、失败重试、安装权限引导、草稿/在途阻塞提示、非首批平台提示 |
| `lib/ui/updates/update_ui_state.dart` | 仅供展示的只读状态快照与各阶段枚举；不含检查/下载/安装机制 |
| `lib/ui/updates/release_notes_view.dart` | Release body 的安全 Markdown 呈现（不执行 HTML、不加载远程图片、不自动打开链接） |
| `lib/updates/android_update_installer.dart` | Android 原生安装通道的 Dart 侧：环境可用性、提交 APK、打开“安装未知应用”设置、安装结果事件 |
| `android/app/src/main/kotlin/ai/bb/bb_mobile/UpdateInstaller.kt` | 原生侧：安装前校验、FileProvider 授权、系统安装 Intent、结果回传 |
| `android/app/src/main/res/xml/update_paths.xml` | FileProvider 仅暴露应用私有 cache/files 目录 |

尚未接入应用导航：设置入口、启动时一次检查、契约 → 界面快照的映射属于契约提交之后的
集成步骤（见文末）。当前页面与安装器均可独立测试，但应用运行时尚无入口。

## 界面状态

`UpdateUiPhase` 与验收要求一一对应：

| 阶段 | 展示 | 可用操作 |
|---|---|---|
| `idle` | 当前版本 + 说明“每次启动后台检查一次，不阻塞聊天” | 检查更新 |
| `checking` | 进度条 + “正在检查更新…” | 无（防重复点击） |
| `upToDate` | “已是最新版本” | 重新检查 |
| `available` | 目标版本号、该 Release 原始正文、下载安装按钮 | 下载并安装 |
| `downloading` | 进度条、已下载/总字节、总大小未知时用不确定进度 | 取消下载 |
| `verifying` | 校验完整性中；不提供安装入口 | 无 |
| `permissionRequired` | 为什么需要“安装未知应用”授权 | 打开安装权限设置 |
| `installing` | 等待系统安装确认；明确“不静默安装、不卸载旧应用” | 重新打开安装界面 |
| `installed` | 已安装版本；需重新打开应用 | 无 |
| `failed` | 具体失败文案；`canRetry` 决定是否显示重试 | 重试 |
| `blocked` | 草稿/在途发送/上传未处理，安装被阻止；不会替用户取消或丢弃 | 去处理（可选） |
| `unsupported` | 首批仅 Windows/Android | 无 |

同一时刻只渲染一个阶段，下载/安装阶段不出现第二个“下载”按钮，对应“一次只允许一项更新”
的界面约束；真正的互斥仍由契约保证。

## Release 正文安全呈现

`ReleaseNotesView` 把 body 当不可信文本处理：

- HTML / `<script>` 只作为字面文字显示，不做 HTML 解析、不执行脚本；
- 不加载远程图片（`![](...)` 只显示 `[图片：alt]`），检查更新不会产生额外网络请求；
- 只有 `http/https` 目标是链接样式，其他 scheme（`javascript:`、`file:`、`intent:` 等）
  保持原文；
- 链接不创建点击手势：打开目标是用户在浏览器中的显式动作，更新页本身不导航、不下载；
- 正文为空时显示“此版本未提供更新说明”，不编造内容；
- 代码围栏横向滚动，长正文在窄屏换行，不溢出。

## Android 安装流程

1. `availability()`：返回 `ready` / `permissionRequired`（API 26+ 未授予“安装未知应用”）
   / `unsupported`，并带上当前包名、versionCode 与设备 ABI 列表。
2. `openInstallPermissionSettings()`：跳转本应用的 `ACTION_MANAGE_UNKNOWN_APP_SOURCES`；
   返回后原生把 `permissionResult` 事件发回（`granted` / `denied`）。
3. `installApk(path)`：原生先做安装前校验，全部通过才打开系统安装器：
   - 文件存在、`.apk` 后缀、非空；
   - 路径规范化后必须位于本应用私有 `cacheDir` / `filesDir` / `externalFilesDir` 之内，
     符号链接或 `..` 逃逸一律拒绝；
   - `PackageManager.getPackageArchiveInfo` 能解析，包名等于当前应用；
   - APK `versionCode` 严格大于已安装版本（不降级、不重复安装同版）；
   - APK 签名证书 SHA-256 集合与已安装应用一致（不换签名密钥）；
   - APK 内 `lib/<abi>/` 与本机 `SUPPORTED_ABIS` 有交集（分 ABI 包架构不符直接拒绝）。
4. 校验通过后用本应用 `FileProvider`（`${applicationId}.updates`）生成一次性只读 URI，
   以 `ACTION_VIEW` + `application/vnd.android.package-archive` 交给系统安装器；用户确认、
   权限与最终签名校验都由系统负责，客户端不静默安装、不卸载旧应用。
5. 用户从安装界面返回后，原生读取 `onActivityResult`：`RESULT_OK` 且重新查询到的
   versionCode 不小于目标版本才报 `installed`；否则报 `cancelled` / `unverified`，
   **不把“打开了安装器”当成安装成功**。结果同时通过 `updateEvent` 推送并缓存，供
   重新进入界面的调用方用 `takeLastEvent()` 取回。安装期间进程可能被系统结束，原生
   内存不跨进程；重启后由契约比较 `availability()` 返回的已安装 versionCode 判断是否
   已升级，而不是假设一定收到结果事件。

拒绝原因（`ApkInstallRejection`）到用户文案的映射在 `update_ui_state.dart`，每个原因
都有独立文案；未知 code 归为 `unknown`，不猜测为更具体的成功或失败。

## 验证

已实跑（Linux 主机，Flutter 3.47.9 / Dart 3.13.7）：

```bash
# 新增界面与安装通道测试 34 例（11 安装通道 + 7 Release 正文 + 16 设置页）
flutter test test/update_release_notes_test.dart \
  test/update_settings_page_test.dart \
  test/android_update_installer_test.dart

# 客户端全量
flutter test            # 584 passed, 9 skipped（8 为既有 skip，1 为可选截图用例）
flutter analyze         # No issues found

# Android release 构建（JDK 17，Flutter 3.47.9，ANDROID_HOME 指向本机 SDK）
flutter build apk --release --target-platform android-arm64
# ✓ Built build/app/outputs/flutter-apk/app-release.apk (22.9MB)，exit 0
# versionCode 2 / versionName 0.0.1；签名 CN=Android Debug（仓库 debug.keystore）
# merged manifest 含 REQUEST_INSTALL_PACKAGES 与
# provider androidx.core.content.FileProvider authorities=ai.bb.bb_mobile.updates
```

界面证据（widget-test 渲染，非真机）：`test/update_settings_screenshot_test.dart` 可用
`QA_UPDATE_SCREENSHOT_DIR` 生成 390×844 与 1280×800 的
available / downloading / permissionRequired / failed / blocked 截图。

## NOT RUN（未测项，不冒充通过）

- **真机安装**：当前环境 `adb devices -l` 无设备。安装/取消/权限拒绝/重装覆盖的系统弹窗
  流程、`applicationId` 与签名连续性在真实设备上的表现均 **NOT RUN**；
- **Windows 更新执行器/恢复**：Windows runtime 离线，由 Forge 的 Windows CI/执行器覆盖，
  不在本文件声称；
- **计划/权限异常机型**：不同 OEM 对 `ACTION_VIEW` 安装 Intent 的定制行为未测。

## 待契约提交后完成的集成（交给 Forge 接续）

1. 在 `lib/main.dart` 创建契约控制器（仅一次进程生命周期），启动时触发一次自动检查；
2. Profile 面板增加“设置”入口 → `UpdateSettingsPage`，并用 `AnimatedBuilder`/
   `ValueListenableBuilder` 把契约状态映射为 `UpdateUiState`；
3. 回调接线：`onCheck` → 契约手动检查；`onDownloadAndInstall` → 下载并校验；`onCancelDownload`
   → 取消；`onRetry` → 重试失败步骤；`onOpenInstallPermissionSettings` /
   `onResumeSystemInstaller` → `AndroidUpdateInstaller`；`onReviewPendingWork` → 回到聊天
   草稿/上传处理入口；
4. 安装前安全门（草稿、在途发送/上传）由 Forge 的 `services/` 规则给出 `blocked` 原因，
   UI 只负责显示与“去处理”入口；
5. 契约需区分“同版本/更旧/预发布不提示”的结果，UI 用 `upToDate` 表达，不再另做比较；
6. 重启后安装结果判定：用 `AndroidUpdateInstaller.availability()` 的已安装 versionCode
   与目标版本比较，不依赖已丢失的进程内事件。
