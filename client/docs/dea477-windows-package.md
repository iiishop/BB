# DEA-477 Windows 测试包：自带自建 FFmpeg

状态：可执行修复 + CI 打包交接，不是 Windows 原生验收通过。Windows 人工实测由用户完成；
CI 通过只证明构建、包内容与可自动化的包内二进制路径。未合并、未部署、未发布正式版本。

## 1. 要求与结论

用户补充要求：Windows 交付包不能依赖用户系统 PATH 里的 ffmpeg；包内必须携带运行所需
FFmpeg，程序按应用安装目录解析调用，不修改全局 PATH，删除应用即随包移除。

本轮交付：

- Windows release 包内置**从固定源码自建**的最小 FFmpeg（LGPL），放在应用目录的
  `ffmpeg/ffmpeg.exe`；同目录携带 LGPL-2.1 全文、LGPLv3/GPLv3 参考文本、zlib 许可、
  `FFMPEG-NOTICE.txt` 与记录哈希/源码/配置的 `BUILD-MANIFEST.txt`。
- 客户端通过 `resolveFfmpegExecutable()` 从**应用可执行文件所在目录**解析
  `ffmpeg/ffmpeg.exe`（兼容旧式同目录 `ffmpeg.exe`）；只有开发构建（未打包二进制）才回退
  到 PATH 的 `ffmpeg`。发布包缺失 FFmpeg 时 CMake Release 配置直接失败。
- 只调用 `ffmpeg`，不调用 `ffprobe`/`ffplay`，因此只携带 `ffmpeg.exe`；打包脚本拒绝包含
  `ffprobe.exe`/`ffplay.exe` 的产物。
- Linux/macOS 分发方式未改变（仍使用系统 FFmpeg）；本要求只覆盖 Windows 包。

## 2. 固定源码与构建（不是第三方预编译包）

| 项 | 值 |
| --- | --- |
| FFmpeg 版本 | `8.1.3` |
| FFmpeg commit | `f1acb0a2666c78d92688f4c3d2803a132f5590f6` |
| FFmpeg 源码包 SHA-256 | `3d9e59cb878618b9a334d2ce752fa6d9c6896bff39947bc3c3d299e63088f68d` |
| zlib 版本 | `1.3.1` |
| zlib 源码包 SHA-256 | `9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23` |
| 构建 | MinGW-w64 x86_64，静态链接，`--disable-autodetect`，无 GPL/nonfree |
| 外部库 | 仅 zlib（PNG 压缩）；其余全部为 FFmpeg 内部解码/解复用组件 |
| 产出 | `ffmpeg.exe` 约 24 MiB，PE 导入仅 Windows 系统 DLL |
| 许可 | FFmpeg LGPL-2.1-or-later；zlib license |

`scripts/ci/ffmpeg_pins.py` 是版本/URL/哈希的唯一来源；`scripts/ci/fetch_ffmpeg_sources.py`
下载时强校验哈希（已有缓存只有哈希匹配才复用，改变/缺失即重新下载；`--archive` 也走同一
校验），并生成 `sources.sha256`、`sources.json`、`pins.env`。

`scripts/ci/build_ffmpeg_windows.sh` 每次**清空重建**（不重用旧暂存），从固定源码构建 zlib
静态库和 FFmpeg，并：

- 只启用内部解码/解复用组件与 PNG 编码器、`image2` muxer；关闭 GPL/nonfree 与外部库；
- 检查 `ffmpeg.exe` 的 PE 导入表，拒绝 `libwinpthread`/`libgcc`/`zlib1`/FFmpeg DLL 等非系统依赖；
- 生成 `BUILD-MANIFEST.txt`：源码哈希、exe SHA-256/大小、完整 configure、PE 导入、工具链；
- 生成 `FFMPEG-NOTICE.txt`：版本、commit、源码与构建脚本地址、许可证清单、无源码修改声明、
  对应源码获取方式与“删除应用即移除随包工具”的说明；构建脚本随包为 `BUILD-FFMPEG.sh`，
  manifest 记录 `build_script_git_commit`（CI 传入的候选 SHA）。

`client/windows/CMakeLists.txt` 在 Release 构建中要求 `windows/ffmpeg/` 里同时存在
`ffmpeg.exe`、许可证与声明，否则 `FATAL_ERROR`。

## 3. 许可材料与核对

ZIP 内 `ffmpeg/` 目录包含：

| 文件 | 内容 |
| --- | --- |
| `FFMPEG-LICENSE.txt` | FFmpeg 的 LGPL-2.1 全文（本分发的主许可） |
| `FFMPEG-LGPLv3.txt` | FFmpeg 源码附带的 LGPLv3 文本（参考） |
| `FFMPEG-GPLv3.txt` | FFmpeg 源码附带的 GPLv3 文本（LGPL/GPL 组合条款参考） |
| `ZLIB-LICENSE.txt` | zlib 1.3.1 许可 |
| `FFMPEG-NOTICE.txt` | 版本/commit/源码 URL 与 SHA-256、构建脚本、无修改声明、源码提供方式 |
| `BUILD-MANIFEST.txt` | 上述固定值 + 实际 exe 哈希 + configure 参数 + PE 导入 |
| `BUILD-FFMPEG.sh` | 产生该二进制的构建脚本（与仓库 `scripts/ci/build_ffmpeg_windows.sh` 一致） |

由于本轮不再分发 BtbN 等静态包含多项外部库的预编译包，依赖清单就是 FFmpeg + zlib；
不需要为几十个第三方静态库逐一提供许可/源码。构建关闭 `--enable-gpl`/`--enable-nonfree`，
打包脚本还会在 manifest 的 configure 中拒绝这两个开关与 `--enable-lib*`，避免后续改动
引入未声明的外部依赖或 GPL 组件。

## 4. 构建与打包入口

```bash
# 1) 下载并校验固定源码（已有缓存也必须哈希匹配）
python scripts/ci/fetch_ffmpeg_sources.py --dest .ffmpeg-src

# 2) 在 MSYS2 MINGW64 中从源码构建并暂存（CI 自动执行；本地需要 MinGW-w64）
bash scripts/ci/build_ffmpeg_windows.sh \
  --sources .ffmpeg-src --dest client/windows/ffmpeg

# 3) 构建 Flutter Windows release，然后打包/检查
cd client && flutter pub get && flutter build windows --release && cd ..
python scripts/ci/package_windows.py \
  --bundle client/build/windows/x64/runner/Release \
  --out dist --version 0.2.0 \
  --expected-ffmpeg-sha256 "$(grep '^ffmpeg_exe_sha256=' client/windows/ffmpeg/BUILD-MANIFEST.txt | cut -d= -f2)"
```

`package_windows.py` 的校验入口（bundle 与解压后的 ZIP 都走同一入口）：

- 必需文件/布局与 `data/flutter_assets`；拒绝 `ffprobe/ffplay`；
- `ffmpeg.exe` 的 SHA-256 必须同时等于 `BUILD-MANIFEST.txt` 与构建步骤输出的
  `--expected-ffmpeg-sha256`；大小一致；
- manifest 的版本/commit/源码哈希/zlib 哈希必须等于 `ffmpeg_pins.py` 的固定值；
- configure 必须包含最小构建规则、不得包含 GPL/nonfree/external lib 开关；
- 许可证文件存在且包含预期文本；notice 包含固定版本/哈希/源码提供声明；
- Windows 上把 PATH 收窄到 `%SystemRoot%\System32;%SystemRoot%`，运行包内 `ffmpeg -version`，
  用包内 ffmpeg 对仓库内固定的 H.264/HEVC/VP9 小样本执行与客户端相同的封面参数，校验 PNG
  签名；ZIP 生成后再解压到 `BB 测试 包`（空格 + 中文）重复上述校验与冒烟。

因此“暂存目录里旧/被改过的 ffmpeg.exe”无法进入包：build 每次都重建，package 同时比对
manifest 与构建步骤输出的期望哈希。非 Windows 主机上二进制冒烟显式 `NOT_RUN`，不会伪造 PASS。

## 5. CI 与发布

- `.github/workflows/windows-test-package.yml`（PR 与手动触发）：下载固定源码 → MSYS2 构建 →
  Flutter release 构建 → Windows 单测（解析器 + 粘贴准备）→ 打包/校验/冒烟 → 上传
  `bb-windows-test-package`（ZIP + `SHA256SUMS.txt` + `package-summary.json`）与
  `bb-windows-package-evidence`（打包日志 + manifest）。
- `release.yml` 的 Windows 作业复用同一 fetch/build/package 脚本，main 发布包同样自带 FFmpeg。
- 已用本地 MinGW 交叉编译 + Wine 实测：自建 `ffmpeg.exe` 在收窄 PATH 下可解码 H.264/HEVC/VP9
  样本并输出 PNG；`package_windows.py` 对真实自建包端到端通过；对 exe 追加字节或传入错误
  期望哈希均被拒绝（exit 1）。

## 6. 未自动证明、需 Windows 实测

- 从解压包启动应用后的真实交互：Enter/Ctrl+Enter、中文 IME、截图 Ctrl+V、资源管理器多选、
  保留正文/逐项移除、视频粘贴→封面→待发送→发送、对端收取。
- Windows SmartScreen（未签名）与真实桌面播放器/系统行为。
- CI 构建、包内二进制冒烟与 Linux/mock 测试不冒充 Windows 原生验收；这些由用户按 issue
  评论中的短清单实测。

## 7. 已知限制

- 包未做 Authenticode 签名，首次运行会弹 SmartScreen（“更多信息 → 仍要运行”）。
- 测试包是免安装 ZIP；删除解压目录即移除应用与随包 FFmpeg，不写系统 PATH、不装系统级依赖。
- 自建最小 FFmpeg 只保留内部解码器；极少数依赖外部解码库的编码格式不在此包内（客户端只
  用它抽封面）。若未来需要更多编解码器，必须同步更新固定源码/依赖许可/源码提供材料并重新
  打包，不能沿用本文件结论。
- Linux/macOS 仍使用系统 FFmpeg；本次未改变其分发方式。
