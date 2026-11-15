# DEA-477 输入发送/换行与 Ctrl+V 任意文件粘贴

状态：客户端修复交接，不是独立 QA 或产品验收。基线 `a0fcb70bdd971154b1a63f21d5a82c8ced35ff8a`，
写入范围仅 `client/`；共享契约 `server/contract/src/bb_auth_contract/chat.py` 未改。

## 1. 失效环节（修复前定位）

1. `ChatComposer` 的输入框没有任何快捷键处理：`TextEditingController` 只挂了
   `TextInputAction.newline`，Enter 与 Ctrl+Enter 都只落到多行编辑器的默认行为，从未调用
   `_send()`。发送按钮是唯一发送入口。
2. 桌面剪贴板读取只实现了 Linux 的 `wl-paste` / `xclip` / `xsel`。Windows 上这些进程不存在，
   `PlatformClipboardMediaReader.read()` 永远返回 null，所以 Ctrl+V（当时根本没有绑定）和
   “粘贴图片或视频”按钮都不可能读到内容。
3. 旧按钮走的是“单张图片/视频”通道：文件 URI 只接受图片/视频 MIME，且只取第一个 URI；没有
   多文件，也没有任意普通文件进入附件链路的路径。

## 2. 交互约定

- 输入框聚焦时：**Enter 发送**，**Ctrl+Enter 换行**；Shift/Alt/Meta+Enter 交给编辑器。
- 中文 IME 组词/选字期间（`TextEditingValue.composing.isValid`）Enter 不发送。
- Enter 长按/重复事件不重复提交；Ctrl+V 重复事件不重复粘贴。
- 空正文且无待发送草稿时不发送；发送仍走原 `_send()`（局部气泡、幂等 operation、失败重试不变）。
- 桌面输入框 hint 与实际快捷键一致（`输入消息… Enter 发送，Ctrl+Enter 换行`，不用 ` · `
  以免与顶栏 `账号 · 在线状态` 的单行断言混淆），发送按钮
  tooltip 为“发送（Enter）”；手机软键盘保持原来的换行 + 发送按钮，不新增设置项。
- 删除专用“粘贴图片或视频”按钮；图片/文件选择入口保留。
- Ctrl+V：剪贴板里有文件/图片时进入待发送区，不自动上传、不自动发送；纯文本时按光标位置插入，
  保留原有编辑行为。多文件按剪贴板顺序加入，可逐项删除。
- 图片进入有序正文草稿；视频（真实封面）、音频、PDF、ZIP 及其他普通文件进入独立附件。
  多文件保持剪贴板顺序进入附件组，图片保持正文插入顺序。
- 文件不存在/是文件夹/为空/超过 32 MiB/不可读时给可见提示（SnackBar），其余文件仍加入，
  不静默丢弃；未知 MIME 以 `application/octet-stream` 发送，由服务端归为契约已有的 `other`。

## 3. 实现位置

| 文件 | 变更 |
| --- | --- |
| `client/lib/ui/chat/chat_composer.dart` | FocusNode 按键处理、Ctrl+V 入口、文本/换行插入、多文件草稿、问题提示、删除旧按钮、hint/tooltip |
| `client/lib/ui/chat/clipboard_paste.dart`（新增） | `ClipboardPaste`、`ClipboardMediaReader`、Linux/Android 读取、Windows PowerShell 读取与 listing 解析 |
| `client/lib/ui/chat/media_actions.dart` | 移出剪贴板实现，保留文件选择/封面/保存；`extensionForMime` 复用 |
| `client/lib/services/media_source.dart` | `m4a/m4b/f4a` 不再被 `ftyp` 误判为 `video/mp4`（服务端只收 mp4/webm 视频且要求封面，音频容器改走 `other`） |
| `client/lib/ui/chat/chat_page.dart` | 剪贴板 seams 改用 `clipboard_paste.dart` |

## 4. Windows 剪贴板实现

Windows runner 没有剪贴板插件，本轮用系统自带 PowerShell（不安装新工具链）：

- `-NoProfile -NonInteractive -STA -WindowStyle Hidden -EncodedCommand <base64 UTF-16LE>`；
  `-STA` 是 `System.Windows.Forms.Clipboard` 的要求。
- 先读 `ContainsFileDropList()`（资源管理器单/多选 = CF_HDROP），否则
  `ContainsImage()`（截图/复制图像 = CF_DIB）→ 保存为 PNG。
- 结果写入私有临时目录里的 UTF-8 listing（`FILE<TAB>path` / `IMAGE<TAB>png`），不依赖控制台
  代码页，中文文件名不经过 stdout；读取后删除临时目录。
- 每个文件在 Dart 侧重新检查存在性/类型/大小并重新 sniff MIME；目录、空文件、超 32 MiB、
  不可读、已删除分别给提示。
- 依赖：`powershell.exe`（Windows 11 自带；失败再尝试 `pwsh.exe`）。视频封面在 Windows
  使用随包自建的 `ffmpeg/ffmpeg.exe`（LGPL-2.1+，固定 FFmpeg 8.1.3 + zlib 1.3.1 源码构建；
  应用目录解析、不依赖 PATH；版本/哈希/许可/源码材料见 `dea477-windows-package.md`）；
  Linux/macOS 仍用系统 `ffmpeg`。找不到可用 ffmpeg 时提示“未找到可用的 ffmpeg”。

限制：只处理文件列表、原始图片和纯文本；不读取第三方软件私有/虚拟剪贴板格式；PowerShell
冷启动会带来约数百毫秒的粘贴延迟；Windows 上仍可能有短暂的隐藏窗口开启开销。

## 5. 契约

- 未改共享契约。`chat.py` 的 `Media.media_type` 已含 `document`/`other`；
  `MIMES` 白名单外（zip、其他二进制、m4a 等）由客户端以 `application/octet-stream` 发送并落到
  `other`，`document` 覆盖 pdf/text。
- 服务端只把 `audio/mpeg`、`audio/wav` 归为音频；其他音频容器（如 m4a、audio-only webm/mp4）
  按普通文件 `other` 发送。这是现有契约的能力边界，不是本轮客户端缩窄；若产品要求更多音频类型
  按音频渲染，需要服务端扩充 `MIMES`。
- 未发现需要修改服务端的真实缺口。

## 6. 测试与证据

环境：Linux x86_64，Flutter 3.47.9 / Dart 3.13.7；Windows 运行时 offline，Xvfb 在本机
segfault，因此 Linux 桌面窗口/集成测试 NOT RUN。

修前（基线 `a0fcb70`，同一测试文件）：

| 命令 | 结果 |
| --- | --- |
| `flutter test test/chat_composer_shortcuts_test.dart` | exit 1；4 失败：Enter 发送（实际 0 次）、Ctrl+Enter 换行、长按不重复、旧粘贴按钮仍在；2 通过（IME、空白不发） |
| `flutter test test/clipboard_paste_probe_test.dart`（临时行为探针，已删） | exit 1：Ctrl+V 后 clipboard 读取次数 0，草稿为空 |

修后：

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found!`，exit 0 |
| `flutter test` | 527 passed / 8 skipped，exit 0（基线 498 passed / 8 skipped） |
| `flutter test test/chat_clipboard_paste_test.dart test/chat_media_input_test.dart` | 27 passed，exit 0 |
| `flutter test test/chat_media_input_test.dart test/chat_send_feedback_test.dart test/chat_local_media_preview_test.dart` | 57 passed，exit 0 |
| `flutter build linux --debug` | 构建成功 exit 0（只证明编译，不代表窗口/运行） |

未测：Windows 运行时（PowerShell CF_HDROP/CF_DIB、真实 Ctrl+V、资源管理器多选）、Linux 桌面
GUI/集成测试、Android 真机、Windows 构建。上述剪贴板逻辑仅有 listing/脚本/文件收集/组件层
单测与 Linux widget test 证明，不能替代真实 Windows 验收。

## 7. 返工：audio-only WebM（Sentinel 反例）

Sentinel 复验确认的验收缺陷：合法纯音频 WebM（Opus，无视频轨）被 `sniffMime` 的 EBML magic
一律判为 `video/webm`，随后 `ChatComposer::_addAttachment` 强制要求封面帧，导致文件无法进入
待发送区。修复不是按文件名特判，而是按容器真实轨道分类：

- `media_source.dart` 新增 `hasVideoTrackInContainer(bytes)`：对 Matroska/WebM（EBML）解析
  `Segment → Tracks → TrackEntry → TrackType`（1 = video）；对 ISO-BMFF（ftyp）解析
  `moov → trak → mdia → hdlr`，`vide` 才算视频。容器未知/截断/损坏时返回 null，保持原 magic
  分类，不靠猜测放宽。
- `sniffMime` 仅在没有视频轨时把 mp4/webm 归为 `application/octet-stream`（契约 `other`）；
  有视频轨保持 `video/mp4`/`video/webm`。
- 准备规则再加一层防御：若某个来源仍声明 `video/*` 但取封面失败且容器确实无视频轨，
  `_addAttachment` 降级为 `other` 并以 `application/octet-stream` 发送，不再卡住发送。
  真实视频取封面失败仍给原有可见错误。

修前/修后（同一临时行为探针：Windows 文件列表 seam 读真实 `test/fixtures/media/audio-only.webm`
→ Ctrl+V → 期望草稿中出现文件名）：

| 树 | 结果 |
| --- | --- |
| 上一候选 `4140984` | exit 1：`Found 0 widgets with text "audio-only.webm"`，文件未进入待发送区 |
| 本次修复 | exit 0：1 passed；文件名出现、无“提取视频封面”错误、可发送为 `application/octet-stream` |

Sentinel 的 `review/dea477/paste_probe_test.dart` 中 audio 用例把“出现提取封面错误”也写成断言，
修复后该断言按设计失败；其 3 个异步安全性场景在修复后仍通过。对应期望行为已移植进默认
`test/chat_clipboard_paste_test.dart`（无错误、可移除、可发送），并补充：
`audio-only webm` 轨道检测、`audio-only mp4`（isom 音频）轨道检测、真实 video webm/mp4 仍为视频、
以及 `video/*` 声明但无视频轨时降级为 `other` 的准备规则回归。

本轮 `flutter test` 527 passed / 8 skipped / exit 0；`flutter analyze` clean；
`flutter build linux --debug` 成功。Windows 原生验收、Linux 桌面 GUI/集成、Android 仍为
**NOT RUN**（Windows runtime offline；本机 Xvfb segfault）。
