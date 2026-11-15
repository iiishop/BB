## BB 0.0.1

首个编号发布，基于已合并的 Windows 内置 FFmpeg 工作（PR #28）。这是早期自托管客户端，不包含服务端安装包。

### 构建与验收

- 正式发布只由与 `client/pubspec.yaml` 匹配的 tag push 触发；发布前在同一个提交上调用完整 CI（既有 Flutter 三层 QA、服务端/插件与管理入口测试）。
- Windows ZIP 使用 PR #28 的固定源码 FFmpeg 构建、许可/manifest 校验与打包入口；Windows runner 运行应用目录解析和粘贴准备单元测试，并在无系统 FFmpeg 的 PATH 下解码 H.264/HEVC/VP9 封面，再从中文/空格目录解压复验。
- **Windows 人工验收未完成**：真实中文输入法候选/组合输入与 Enter 行为、系统剪贴板图片/文件粘贴、不同桌面环境下的视频交互仍需人工验证。自动化测试不等于这些 GUI 场景已通过。
- Linux、Windows、macOS、Android 均由原生 runner 构建；下载后请使用 `SHA256SUMS` 校验。构建通过不等于已在每个平台真机安装/升级测试。

### 签名与安装边界

- Android APK/AAB 使用仓库内公开的 **debug keystore**，不是生产签名，不能用于应用商店正式分发。
- Windows 未做 Authenticode 签名；macOS 未使用 Developer ID 签名/公证，系统可能拦截运行。未提供签名证书，不声称已解决 SmartScreen/Gatekeeper。
- 应用户指定，展示版本从开发版本 `0.2.0` 重置为 `0.0.1`，构建号从 `1` 增至 `2`。Android `applicationId` 仍是 `ai.bb.bb_mobile`；单 ABI APK 的 versionCode 还受 Flutter ABI 偏移影响。同签名、同 ABI、较低 versionCode 的旧包通常满足升级必要条件，但**未验证覆盖安装，也不保证所有旧安装能覆盖**（尤其跨 ABI/自签名构建）。先备份数据。
- Linux 包版本 `0.0.1` 小于旧开发包 `0.2.0`，包管理器可能将其视为降级，不能声称自动升级。Windows/macOS ZIP 是便携包，不是升级安装程序；不要直接覆盖正在运行的目录。

### Windows FFmpeg

内置最小 FFmpeg 8.1.3 + zlib 1.3.1，附许可证、源码获取信息、构建脚本与精确构建提交。见包内 `ffmpeg/FFMPEG-NOTICE.txt` 和 `BUILD-MANIFEST.txt`。未打包 ffprobe/ffplay，不依赖用户 PATH 上的 FFmpeg。
