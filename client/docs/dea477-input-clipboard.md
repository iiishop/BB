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
- 桌面输入框 hint 与实际快捷键一致（`输入消息… Enter 发送 · Ctrl+Enter 换行`），发送按钮
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
- 依赖：`powershell.exe`（Windows 11 自带；失败再尝试 `pwsh.exe`）。桌面视频封面仍依赖
  `ffmpeg` 在 PATH，这是既有约束；缺失时提示“桌面需要 ffmpeg”。

限制：只处理文件列表、原始图片和纯文本；不读取第三方软件私有/虚拟剪贴板格式；PowerShell
冷启动会带来约数百毫秒的粘贴延迟；Windows 上仍可能有短暂的隐藏窗口开启开销。

## 5. 契约

- 未改共享契约。`chat.py` 的 `Media.media_type` 已含 `document`/`other`；
  `MIMES` 白名单外（zip、其他二进制、m4a 等）由客户端以 `application/octet-stream` 发送并落到
  `other`，`document` 覆盖 pdf/text。
- 服务端只把 `audio/mpeg`、`audio/wav` 归为音频；其他音频容器（如 m4a）按普通文件 `other`
  发送。这是现有契约的能力边界，不是本轮客户端缩窄；若产品要求更多音频类型按音频渲染，需要
  服务端扩充 `MIMES`。
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
| `flutter test` | 519 passed / 8 skipped，exit 0（基线 498 passed / 8 skipped） |
| `flutter test test/chat_composer_shortcuts_test.dart test/chat_clipboard_paste_test.dart` | 19 passed，exit 0 |
| `flutter test test/chat_media_input_test.dart test/chat_send_feedback_test.dart test/chat_local_media_preview_test.dart` | 57 passed，exit 0 |
| `flutter build linux --debug` | 构建成功 exit 0（只证明编译，不代表窗口/运行） |

未测：Windows 运行时（PowerShell CF_HDROP/CF_DIB、真实 Ctrl+V、资源管理器多选）、Linux 桌面
GUI/集成测试、Android 真机、Windows 构建。上述剪贴板逻辑仅有 listing/脚本/文件收集/组件层
单测与 Linux widget test 证明，不能替代真实 Windows 验收。
