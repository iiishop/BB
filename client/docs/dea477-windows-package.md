# DEA-477 Windows 测试包：自带 FFmpeg

状态：可执行修复 + CI 打包交接，不是 Windows 原生验收通过。Windows 人工实测由用户完成；
CI 通过只证明构建、包内容与可自动化的包内二进制路径。

## 1. 要求与结论

用户补充要求：Windows 交付包不能依赖用户系统 PATH 里的 ffmpeg；包内必须携带运行所需
FFmpeg，程序按应用安装目录解析调用，不修改全局 PATH，删除应用即随包移除。

本轮交付：

- Windows release 包内置固定版本、固定哈希的 FFmpeg（LGPL 构建），放在应用目录的
  `ffmpeg/ffmpeg.exe`，同目录携带 `FFMPEG-LICENSE.txt` 与 `FFMPEG-NOTICE.txt`。
- 客户端通过 `resolveFfmpegExecutable()` 从**应用可执行文件所在目录**解析
  `ffmpeg/ffmpeg.exe`（兼容旧式同目录 `ffmpeg.exe`）；只有开发构建（未打包二进制）才回退
  到 PATH 的 `ffmpeg`，发布包缺失 FFmpeg 时 CMake Release 配置直接失败。
- 只调用 `ffmpeg`，不调用 `ffprobe`/`ffplay`，因此只携带 `ffmpeg.exe`，不夹带未使用组件；
  打包脚本会拒绝包含 `ffprobe.exe`/`ffplay.exe` 的产物。
- Linux/macOS 分发方式未改变（仍使用系统 FFmpeg）；本要求只覆盖 Windows 包。

## 2. 固定构建与许可

| 项 | 值 |
| --- | --- |
| FFmpeg 版本 | `n8.1.3-35-gf1acb0a266`（release/8.1） |
| 上游 commit | `f1acb0a2666c78d92688f4c3d2803a132f5590f6` |
| 构建 | BtbN / FFmpeg-Builds `win64-lgpl` 静态构建 |
| 发布 tag + 资产 | `autobuild-2026-11-15-12-40` / `ffmpeg-n8.1.3-35-gf1acb0a266-win64-lgpl-8.1.zip` |
| 压缩包 SHA-256 | `272140baa96cbb9553eb57c03590e0b8d2c93ce352aa7f876c34fbc657536836` |
| 许可 | LGPL-3.0（该构建的 `LICENSE.txt`；FFmpeg 上游亦提供 LGPL-2.1-or-later） |

`scripts/ci/fetch_ffmpeg_windows.py` 固定上述 URL/哈希；下载后校验 SHA-256，解压只取
`bin/ffmpeg.exe` 与 `LICENSE.txt`，并生成 `FFMPEG-NOTICE.txt`（版本、commit、构建 tag、
资产哈希、许可证、无修改声明、源码与构建脚本获取地址）。`--archive` 复用本地压缩包时
同样校验哈希，避免“不校验的本地文件”进入发布包。

许可证义务按实际构建核实：该构建为 LGPL 变体，未启用 GPL-only 组件；包内提供许可证
全文、精确源码/构建脚本地址与未修改声明。若后续更换构建（GPL/共享 DLL 等），必须重新
核实许可、依赖 DLL 与源码提供方式，不能沿用本文件的结论。

## 3. 构建与调用链

```bash
# 1) 下载并校验固定 FFmpeg，暂存到 client/windows/ffmpeg/
python scripts/ci/fetch_ffmpeg_windows.py --dest client/windows/ffmpeg

# 2) 构建（Release 缺少内置 FFmpeg 会在 CMake 阶段失败）
cd client
flutter pub get
flutter build windows --release

# 3) 打包、检查 ZIP、无系统 FFmpeg 冒烟、中文/空格路径复验
cd ..
python scripts/ci/package_windows.py \
  --bundle client/build/windows/x64/runner/Release \
  --out dist --version 0.2.0 \
  --name bb-0.2.0-windows-x64-dea477
```

- `client/windows/CMakeLists.txt`：存在 `windows/ffmpeg/ffmpeg.exe` 时把整个目录安装到
  bundle 的 `ffmpeg/` 下；Release 缺少 `ffmpeg.exe`/许可证/声明时 `FATAL_ERROR`，Debug/Profile
  仅警告并回退 PATH（仅开发便利，不能作为发布包验收）。
- `client/lib/services/ffmpeg_tool.dart`：`resolveFfmpegExecutable()` 以
  `Platform.resolvedExecutable` 所在目录为锚点，解析 `ffmpeg/ffmpeg.exe`，支持
  `BB_FFMPEG_PATH` 仅作开发/QA 覆盖；不读当前工作目录。
- `client/lib/services/media_source.dart`：`FfmpegVideoCoverExtractor` 默认使用上述解析结果；
  视频封面仍用同一组 `-ss 0 -frames:v 1 -f image2 -vcodec png` 参数。

## 4. CI 与证据边界

`Windows test package` 工作流（`.github/workflows/windows-test-package.yml`，PR 与手动触发）：

1. 下载并校验固定 FFmpeg，记录 runner 自带 ffmpeg 仅作诊断；
2. `flutter build windows --release`；
3. `flutter test test/ffmpeg_tool_test.dart test/chat_clipboard_paste_test.dart`；
4. `package_windows.py` 校验 bundle 布局（`bb_client.exe`、`data/flutter_assets`、
   `ffmpeg/ffmpeg.exe` + 许可证 + 声明）、拒绝 `ffprobe/ffplay`、把 PATH 收窄到系统目录后
   运行包内 `ffmpeg -version`、用包内 ffmpeg 生成 sample 视频并按客户端参数生成封面 PNG、
   打 ZIP、检查 ZIP 条目、解压到含空格与中文的临时目录后重复校验与冒烟；
5. 上传 `bb-windows-test-package` artifact（ZIP + `SHA256SUMS.txt` + `package-summary.json`）。

`release.yml` 的 Windows 发布作业复用同一 fetch + package 脚本，main 发布包同样自带 FFmpeg。

能自动证明的：包内有完整可执行 FFmpeg、包内二进制在无系统 ffmpeg 的 PATH 下可解码并输出
封面 PNG、ZIP 布局完整、中文/空格解压路径可用、Linux 侧解析器与应用目录锚点单测通过。
不能自动证明、必须 Windows 人工实测的：真实 `Ctrl+V`/IME/控件交互、从解压目录启动桌面应用
后的视频粘贴→封面→待发送→发送、对端收取、SmartScreen 提示等。

## 5. 已知限制

- 包未做 Authenticode 签名，首次运行会弹 SmartScreen；用户可“更多信息 → 仍要运行”。
- 测试包是免安装 ZIP；删除解压目录即移除应用与随包 FFmpeg，不写系统 PATH、不装系统级依赖。
- 包内 FFmpeg 为静态 LGPL 构建，体积较大（`ffmpeg.exe` 约 126 MiB；ZIP 约 50–80 MiB）。
- Linux/macOS 仍使用系统 FFmpeg；本次未改变其分发方式。
- Windows 原生快捷键/剪贴板/IME 证据仍需真实 Windows 运行；CI 构建与 mock/Linux 测试不
  能替代。
