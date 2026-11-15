# DEA-482 更换头像：Android 相册选图与桌面“选择图片”

## 规格依据

- 用户要求（issue 正文 revision 1）：Android 的“本机路径”改为打开系统相册选择；桌面保留路径
  输入并增加“选择图片”按钮打开系统原生文件对话框；覆盖内容 URI、取消、不可读、非图片、
  中文/空格路径；选择不等于提交；失败不假成功；不回退已有资料读取与登录。
- 必要工程条件（Orion 派发）：独立工作树与分支、统一头像处理链、修前失败/修后通过证据。
- 额外建议：无。

## 基线与范围

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/iiishop/BB |
| 基线 | `main` @ `573f3877cb8497d9df4720be3c13eee089ff9642` |
| 分支 | `agent/muse/dea-482-avatar-picker` |
| 本机 | Linux（Arch），Flutter 3.47.9 / Dart 3.13.7，无 adb 设备 |
| 环境补充 | 沙箱根文件系统只读，使用工作区内可写的 Flutter/pub/Gradle 副本（不提交）；`Xvfb` 默认 GLX 会段错误，改用 `-extension GLX` + mesa 软件 GL 后可跑真实 Linux 入口 |

写入范围：`client/lib/ui/profile/profile_panel.dart`、新增
`client/lib/ui/profile/avatar_picker.dart`、`client/lib/services/profile_service.dart`
（新增按字节上传的入口）、对应测试、本文件与 `client/README.md`。
未修改 DEA-480 独占的剪贴板/聊天媒体实现、`.github/workflows/windows-test-package.yml`、
`client/test/windows_clipboard_native_diag_test.dart`；未修改 DEA-481 的 `server/`。

## 实现

### 统一头像处理链

```text
系统选择器（Android 相册 / 桌面原生对话框）或手填绝对路径
  -> AvatarSourceReader.readPath      绝对路径 + ≤5 MiB + magic bytes（手填/桌面选中）
     或 picker 返回的字节             magic bytes（Android 内容 URI 副本）
  -> isDecodableAvatarImage           真实解码（target 256px，防小文件超大尺寸）
  -> 对话框预览                       （此时不上传、不改服务端头像）
  -> “应用”                          唯一提交动作
  -> ProfileService.updateAvatarFromPath / updateAvatarFromBytes
  -> validateAvatarBytes + POST /me/avatar（服务端再归一化 PNG）
```

- 选择/填写只同步字段与预览；点“应用”才进入上传。取消选择、取消对话框、上传失败都不会
  清空旧头像或显示成功。
- 远程 URL 与 Base64 两种既有来源的语义、服务端接口、MCP 工具均未改动。

### Android

- `Theme.of(context).platform == TargetPlatform.android` 时隐藏路径输入，显示“从相册选择”。
- 复用已有 `file_selector`（无新依赖）：图片类型组映射到
  `ACTION_OPEN_DOCUMENT` + image MIME 过滤，进入系统相册/最近界面；SAF 不需要存储或相册权限。
- 读取选择结果的字节上传（`updateAvatarFromBytes`），不假定内容 URI 有可用的文件路径。

### 桌面

- 保留路径输入框，右侧新增“选择图片”，调用 `file_selector` 的原生文件对话框（带“图片”过滤器）。
- 选中后回填路径字段、立即预览，字段仍是唯一提交源；取消对话框不改字段、预览与旧头像。

### 其它修正

- 错误文案走既有 `AuthFailure` 的中文字段消息（相对路径/不可读/超限/格式），解码失败单独提示
  “这个文件无法解码为图片”，不把底层异常透给用户。
- 真实 Linux 入口发现长路径会把 `AlertDialog` 撑到接近整窗：内容宽度限制为 360，并新增回归
  断言（`profile_avatar_pick_test.dart` 的“long path does not stretch the dialog”）。

## 第一次 QA 返工（P2：切换来源后选择器卡死）

独立 QA 复验确认一个 P2：选中图片后，在解码尚未完成时切到“图片链接”再切回“本机路径”，
旧解码完成时 `_pick` 因 token 失效直接返回，`_picking` 没有收尾，导致“选择图片”永久禁用，
必须关闭重开对话框。

根因是忙碌状态的归属错了：`_selectKind`/文本失效只应让**结果**过期，却同时（或不）管理
`_picking`/`_reading` 的收尾，而异步完成路径在结果过期时提前返回。修复为“谁启动谁释放”：

- 以计数 `_pendingPicks`/`_pendingReads` 表示真实在途工作，`_picking`/`_reading` 由它派生；
  每个异步操作在 `finally` 中释放自己的一份，取消、失败、过期结果都释放。
- `_selectKind`/`_onPathChanged` 只做失效与预览清理，不再手工改忙碌标志。
- 选图拆为 `_pick`（计数/`finally`）→ `_requestPick`（选择器异常文案）→ `_applyPick`
  （校验+预览）。

回归：QA 的 review-only 探针（`avatar_async_probe.dart`，switchSource 对照 + 失败例）修复前
`1 passed / 1 failed / exit 1`，修复后 `2 passed / exit 0`；同样的场景与预览读取失效、
过期选图重试、待解码时关闭对话框等生命周期用例已并入默认测试入口
`client/test/profile_avatar_async_state_test.dart`。

## 第二次 QA 返工（P2：新输入被旧选图结果覆盖）

第二轮复验确认同机制的剩余 P2：选中 `/qa/avatar.png` 后解码未完成时手填 `/qa/new.png`，
100 ms 后旧解码返回会把字段改回 `/qa/avatar.png`（400 ms 对照通过）。

根因是**失效时机**归属错了：`_onPathChanged` 只在 350 ms 防抖触发（或输入清空）后才让 token
失效，期间旧 `_applyPick` 仍然拥有 token，于是覆盖了更新的输入。修复为单一“候选代”而不是
再追加时序特判：

- `_readToken` 改为 `_generation`（候选代）。**每次编辑立刻自增**（不等防抖）、切换来源、
  开始新一轮选图同样自增；防抖只延迟“开始读取新预览”，不决定归属。
- 每个异步操作在启动时捕获当时的代，落地前校验代仍当前：旧选图解码、旧预览读取、旧的应用
  校验都不能覆盖新输入；不匹配时只丢弃结果，忙碌计数仍在 `finally` 释放。
- 编辑时立即清空预览（字段已不代表旧图片），避免“旧图 + 新路径”的错配状态。

回归：QA 第二轮 review-only 探针（`typing_probe.dart`，delay=100/400）修复前
`1 passed / 1 failed / exit 1`，修复后 `2 passed / exit 0`；其场景与“旧预览不得落到新输入”、
“手填后立即应用应提交新路径”已并入默认入口
`client/test/profile_avatar_async_state_test.dart`（该文件现 9 例：两轮返工的探针场景 + 生命周期）。

## 测试

### 修前失败（基线提交，仅入口断言）

```bash
flutter test test/profile_avatar_entry_test.dart
# 3 failed, exit 1：无 avatar-pick-file / avatar-pick-gallery / avatar-preview
```

原始日志：本轮证据 `pre-fix-avatar-entry-test.log`。

### 修后通过

```bash
flutter analyze          # No issues found! (exit 0)
flutter test             # 655 passed / 9 skipped / exit 0
```

基线为 624 passed / 9 skipped；新增 31 例（含两轮 QA 返工的 9 例异步状态回归）：

| 测试 | 覆盖 |
|---|---|
| `test/profile_avatar_entry_test.dart`（3） | 桌面路径输入 + 选择按钮；Android 无路径输入、有相册入口；预览区域 |
| `test/profile_avatar_pick_test.dart`（14） | 选择≠提交、取消保留输入/预览/头像、关闭不更新、不可读/非图片/无法解码阻止上传、上传失败不显示成功、Android 字节上传、选择器失败可重试并给可读文案、无选择时应用提示、长路径不撑宽 |
| `test/avatar_picker_decode_test.dart`（2） | 真实引擎解码：PNG fixture 通过；截断 PNG/非图片/空字节拒绝 |
| `test/avatar_source_test.dart`（+3） | 中文+空格真实路径、已删除文件、伪装 `.png` 的非图片内容 |
| `test/profile_avatar_async_state_test.dart`（9） | 选图解码期间切换来源后选择器可用（switchSource 对照）、过期选图可重试且只提交重试结果、预览读取期间切换来源释放 spinner 且不落地旧结果、待解码时关闭对话框不抛错；手填新路径在旧解码返回前后都胜出（100/400 ms）、旧预览读取不得落到新输入、手填后立即应用提交新路径 |

覆盖边界：`testWidgets` 的点击驱动不了 dart:io 异步读与引擎解码，因此对话框的
`AvatarSourceReader`/`AvatarDecodeCheck` 是测试 seam；真实 reader 由 `avatar_source_test.dart`
（plain `test`，真实文件）覆盖，真实解码由 `avatar_picker_decode_test.dart` 覆盖。

### 真实 Linux 桌面入口（人工操作 + 截图）

环境：Xvfb `:99`、`-extension GLX`、mesa 软件 GL，真实 FastAPI `127.0.0.1:19182`（独立 SQLite /
头像目录，合成账号）。

1. 打开个人资料 → “更换头像” → 原生 GTK 文件对话框出现（含“图片”类型过滤器）。
2. 手填中文+空格路径 → 预览正确（截图 `gui-11-typed-preview.png`）。
3. 点“选择图片” → 位置栏输入 `/tmp/bb-pick.png` → 选中后路径回填、预览为新图
   （截图 `gui-61-picked.png`）。
4. 点“应用” → 服务端 `avatar_version` 从 `identicon-v1-86b95…` 变为
   `sha256-c18ba32d6d6340ff89e0e9d6813021b87189d8dcf2828bbe9e792a34329ce5e0`，
   `GET /avatars/<account>.png` 返回 841 字节（截图 `gui-62-applied.png`）。
5. 关闭资料面板再打开：仍显示新头像，读取行为无回退（截图 `gui-63-reopened.png`）。
   该流程在两轮 QA 返工后的候选上分别重跑，结果同上。
6. 第二轮返工后另跑“手填路径”入口：输入 `/tmp/bb-pick.png` → 预览 → 应用，服务端
   `avatar_version` 同样变为 `sha256-c18ba32d…`（截图 `gui-71-typed-preview.png` /
   `gui-72-typed-applied.png`）。
7. 不可读路径显示“无法读取该本机路径”，应用不会上传（截图 `gui-12-native-dialog.png`；
   该次为合成按键截断路径，正好验证不可读分支）。

### 构建（仅构建，不等于真机运行）

| 目标 | 命令 | 结果 |
|---|---|---|
| Linux | `flutter build linux --debug` | 成功，`build/linux/x64/debug/bundle/bb_mobile` |
| Android | `flutter build apk --debug` | 成功，`app-debug.apk` 181,808,457 bytes，sha256 `578b7f6f16a530117c1210078b91f1e4e7333acaa22e9423b80839f8128663ff` |
| Android（分 ABI，已签名可安装） | `flutter build apk --release --split-per-abi` | 成功，arm64 20,838,230 bytes，sha256 `29fccef3c23551bf6f559f8749814cf5af078b1da6605f9b571811fefd5c3638`（debug keystore 签名，可安装、不可上架） |

以上构建在第二轮 QA 返工后的候选上重跑。Android 构建日志中 Kotlin daemon 因只读
`~/.local/share` 无法启动，Gradle 回退 in-process 编译后成功（非本次代码问题）。

## NOT RUN / BLOCKED

- **Android 真机/模拟器**：`adb devices` 无连接设备；SDK 无 `emulator` 包与任何
  `system-images`（`flutter emulators` → no sources），宿主也没有 `/dev/kvm`，本环境无法启动
  AVD。系统相册交互（`ACTION_OPEN_DOCUMENT`、内容 URI、取消）**NOT RUN / 环境 BLOCKED**；
  仅完成构建与 widget 层替身验证。需用户按下方步骤在真机复验。
- **Android 权限拒绝**：所用 SAF 选择器不需要存储/相册权限，未构造权限拒绝；以“选择器不可用 /
  读取失败 / 非图片”分支代替。
- **Windows 原生文件对话框**：无 MSVC/Windows 环境，**NOT RUN**；桌面实现走同一
  `file_selector` 调用链，Linux 已验证。
- **Linux `integration_test` 全量**：本轮未跑（Xvfb 默认 GLX 段错误；真实入口已手工跑并截图，
  不等同 CI 集成测试）。

## 用户复验步骤

1. 桌面：`flutter run -d linux` → 左下角头像 → “更换头像” → 手填路径或“选择图片” → 预览 →
   “应用” → 关闭重开资料确认新头像。
2. Android：安装 `app-debug.apk` → 头像 → “更换头像” → “从相册选择” → 选 PNG/JPG → “应用”；
   再试取消、把非图片改名 `.png`、删除后再选，确认无崩溃、无假成功、旧头像保留。
3. 自动化：`flutter analyze` 与 `flutter test`；需要真实链路时另跑
   `QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh client`（需显示服务）。

## 风险与限制

- Android 使用系统文档选择器（SAF，图片过滤），不是 Android 13 Photo Picker；满足“系统相册
  选择”的要求，未新增依赖或权限。
- 未在真机/Windows 上运行，不宣称这两个平台通过；构建成功不代替目标设备验证。
