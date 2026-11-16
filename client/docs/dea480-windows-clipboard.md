# DEA-480 Windows 0.0.2 Ctrl+V 文件粘贴失败（missing extension byte）

状态：客户端修复 + 永久回归 + Windows CI 原生剪贴板链路验证；**未合并、未发布、未做用户验收**。
Windows GUI 用户路径与双账号收发仍为 NOT RUN（见第 7 节）。基线 `573f3877cb8497d9df4720be3c13eee089ff9642`
（v0.0.2 `4a66f434e52b61acaaf2623429f20db0e5db0101`），写入范围仅 `client/` 的剪贴板读取/解码与其测试，
外加既有 Windows CI 的必要接入。

## 1. 根因与原始调用证据

用户报告 PNG/JPG/PDF/文件夹**全部**报 `missing extension byte`。Windows 剪贴板探测本身是成功的：
在 Windows Server 2025（`windows-latest`）上对真实剪贴板执行同一脚本，`FILE`/`IMAGE` listing 均正确写入，
真实 CF_HDROP 文件、中文+空格文件名、文件夹、纯文本、空剪贴板、CF_DIB 像素都能读回（run `43767479772`，
日志见第 6 节）。失败发生在**读取 PowerShell 子进程输出的解码层**：

旧实现（`WindowsClipboardMediaReader._runPowerShell`）：

```dart
final ProcessResult result = await Process.run(
  executable,
  <String>['-NoProfile', '-NonInteractive', '-STA', '-WindowStyle', 'Hidden',
           '-EncodedCommand', encoded],
  stdoutEncoding: utf8,
  stderrEncoding: utf8,       // ← 严格 UTF-8 解码 stderr
);
if (result.exitCode == 0) { ... }
```

Windows PowerShell 5.1 在 **stderr 是重定向流**时，会把进度记录序列化成 CLIXML 写进 stderr，即使脚本
成功（exit 0）也会写。Windows runner 上的原始字节（run `43767479772`）：

```
DIAG[ascii_file] exit=0
DIAG[ascii_file] stderr_hex=233c20434c49584d4c0d0a3c4f626a732056657273696f6e3d... 
DIAG[ascii_file] stderr_lenient=#< CLIXML
DIAG[ascii_file] listing_hex=46494c4509433a5c55736572735c52554e4e45527e315c...7265706f72742e7064660d0a
DIAG[ascii_file] listing_strict=FILE	C:\Users\RUNNER~1\AppData\Local\Temp\...\report.pdf
DIAG[ascii_file] reader files=[report.pdf] problems=[]
```

即 `stderr = "#< CLIXML\r\n<Objs Version=\"1.1.0.1\" ... <AV>Preparing modules for first use.</AV> ..."`，
在英文 Windows 上是纯 ASCII，所以旧代码不会失败（CI 与英文用户的“能粘贴”也是这个原因）。中文 Windows 的
PowerShell 把这句进度/错误文本按控制台 OEM 代码页（CP936）写入，`utf8.decode` 在 `Process.run` 里先抛
`FormatException: Missing extension byte`，**退出码还没被检查**，异常一路冒到 `ChatComposer` 的
`on FormatException catch (error) { _snack(error.message); }`，界面显示的就是 `missing extension byte`。
每次 Ctrl+V 都会启动一次探测，所以文件类型无关、全部失败。

- 复现的最短调用（Linux 单测，`test/chat_clipboard_paste_test.dart`）：把 CP936 的 `你`（`C4 E3`）
  经真实子进程写到 stderr，再用旧参数 `stdoutEncoding: utf8, stderrEncoding: utf8` 调 `Process.run`，
  得到 `FormatException: Missing extension byte`；新探测入口返回失败结果而不再抛异常。
- Windows 原生回归（`test/windows_clipboard_native_test.dart`）用 `[Console]::OpenStandardError()`
  写入同样的 `C4 E3` 字节并 `exit 0`：旧参数抛 `Missing extension byte`，`runWindowsClipboardProbe`
  返回 `ok`。这一条把“修前失败/修后通过”固定在同一台 Windows 原生环境。

## 2. 为什么旧测试没发现

`test/chat_clipboard_paste_test.dart` 的 Windows 用例全部 mock 了原生边界
（`runner: (script, outputPath) ... return true`），并用 `writeAsString` 写 UTF-8 listing；
它验证的是 listing 解析与文件收集，从未运行真实 `powershell.exe`，更没有覆盖 stderr 的本地化编码。
Windows CI 之前只跑 Linux 可复现的解析测试，没有真实剪贴板用例。

## 3. 修复

| 文件 | 变更 |
| --- | --- |
| `client/lib/ui/chat/clipboard_paste.dart` | 探测子进程 stdout/stderr 改为原始字节（`stdoutEncoding/stderrEncoding: null`），退出码是唯一控制信号；stderr 只做宽松解码用于失败诊断；脚本开头把控制台输出编码固定为 UTF-8；listing 读写显式化（UTF-8，兼容 UTF-8/UTF-16 BOM），编码异常给出明确提示；探测失败附带退出码/首行诊断，不再被解码异常掩盖 |
| `client/test/chat_clipboard_paste_test.dart` | 新增 DEA-480 回归组：旧严格解码复现用户错误、非 UTF-8 stderr 不再抛出、listing BOM/非法字节、失败诊断透传 |
| `client/test/windows_clipboard_native_test.dart`（新增） | Windows 原生链路：真实 CF_HDROP 文件（ASCII + 中文/空格）、文件夹明确不支持、纯文本/空剪贴板、CF_DIB 像素→PNG，以及本地化 stderr 的“旧调用失败/新探测通过” |
| `.github/workflows/windows-test-package.yml`、`release.yml` | 既有 Windows 作业加入该原生测试文件，并把文件加入路径过滤 |
| `scripts/ci/package_windows.py`、`test_package_windows.py` | 修复既有 Windows CI 的阻塞回归：FFmpeg 依赖校验在应用构建前执行，不应要求 `bb_updater.exe`/`bb-build.json`；应用载荷要求保留在最终 bundle 校验并新增回归（DEA-479 与 FFmpeg cache 合并后的交叉回归，非本次客户端根因） |

行为不变：文件夹仍明确提示“已跳过文件夹：…”，不新增自动压缩；文件/附件顺序、Enter 发送 /
Ctrl+Enter 换行、失败保留正文与草稿均由原有测试继续覆盖。

## 4. 测试

```bash
cd client
flutter analyze
flutter test test/chat_clipboard_paste_test.dart test/windows_clipboard_native_test.dart
flutter test
```

`test/windows_clipboard_native_test.dart` 顶部 `@TestOn('windows')`，在 Linux 自动跳过；真实执行在
Windows CI 的既有步骤内（见第 5 节）。列表/解码单测在 Linux 与 Windows 都运行，Windows 专属用例在
Windows runner 上运行真实 `powershell.exe`、真实剪贴板与真实 listing 文件。

## 5. 既有 Windows CI 接入

`windows-test-package.yml` 的“Windows 单元测试（应用目录解析 + 粘贴准备）”步骤现在包含
`test/windows_clipboard_native_test.dart`；`release.yml` 的 Windows 作业使用同一命令。没有新增 job
或第二套 CI。该工作流同时产出固定 SHA 的测试 ZIP 与 `SHA256SUMS.txt`。

## 6. 实跑证据

本机：Linux x86_64，Flutter 3.47.9 / Dart 3.13.7。

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found!`，exit 0 |
| `flutter test test/chat_clipboard_paste_test.dart test/windows_clipboard_native_test.dart` | 23 passed（Windows 原生文件在 Linux 跳过），exit 0 |
| `flutter test` | 见交付评论（全量） |
| Windows 原生诊断 run `43767479772` | `ascii_file`/`cjk_file`/`folder`/`image` 真实链路通过；stderr 为 CLIXML（见第 1 节） |

Windows 候选 ZIP 的 SHA-256、下载地址与实跑日志在交付评论中给出（artifact
`bb-windows-test-package`）。

## 7. NOT RUN / 用户复验

以下均**未在本轮执行**，不能由 Linux 测试或 CI 构建代替：

- 解压 Windows Release ZIP 后由用户在真实桌面执行：资源管理器复制 PNG/JPG/PDF/文件夹 → 输入区
  Ctrl+V → 待发送附件 → 实际发送 → 另一合成账号接收/查看/下载（当前无在线 Windows runtime，
  本机 daemon 为 Linux，Windows GUI 为 **NOT RUN / BLOCKED**）。
- 真实 zh-CN Windows 控制台代码页下的端到端复现（CI 用 `C4 E3` 字节与 CLIXML 原始证据锁定机制，
  但没有中文系统镜像）。
- SmartScreen（未签名）、中文/空格路径解压、Windows 原生输入法。
- 其它平台回归（Android 真机、macOS）。

用户复验步骤：

1. 下载候选 run 的 `bb-windows-test-package` artifact，核对 `SHA256SUMS.txt` 与 ZIP SHA-256。
2. 解压到含中文/空格路径（例如 `BB 测试 包`），运行 `bb_client.exe`（SmartScreen 选“更多信息→仍要运行”）。
3. 资源管理器复制单个 PNG、JPG、PDF，各按一次 Ctrl+V，确认进入待发送区且正文/既有附件不丢；发送后由
   另一测试账号接收。
4. 复制文件夹确认提示“已跳过文件夹”，不出现 `missing extension byte`；复制纯文本确认按光标插入；
   截图后 Ctrl+V 确认作为图片进入待发送区。
5. 若仍失败，请提供失败时界面提示原文、Windows 版本、是否以管理员身份启动，以及
   `%LOCALAPPDATA%\Temp\bb-clipboard-*` 是否残留；本轮不再需要旧包的完整异常栈。
