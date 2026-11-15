# CI/CD

PR 门禁（`ci.yml`，也可复用）、发布打包（`release.yml`）和 Windows 测试包。都用 GitHub 官方 runner，不自建。

## 触发条件

| 工作流 | 触发 | 结果 |
| --- | --- | --- |
| `ci.yml` | PR（opened / synchronize / reopened / ready_for_review）、push 到 main、手动 | 只跑改动的子系统；三层 QA + 两套 pytest |
| `release.yml` | push 到 main | 全平台测试构建，文件名含 `.test.<12位SHA>`，artifact 名含 SHA（14 天） |
| `release.yml` | 打 `v*` tag | 同样的构建，另建 GitHub Release 并附 `SHA256SUMS`，最后回下载校验 |
| `release.yml` | 手动（包括选择 tag） | 只生成带 SHA 的测试包，绝不发布 |

版本号只有一处来源：`client/pubspec.yaml` 的 `version`。打 tag 时如果 tag 名跟它对不上，`meta` 作业直接失败，不会静默发出一版错版本。

## PR 门禁做什么

`plan` 按依赖关系裁剪 PR 的子系统测试；push/dispatch/tag 则覆盖所有现存子系统。正式发布通过本地 `workflow_call` 调用同一提交的 `ci.yml`，Release job 必须等待它成功；不轮询另一个可能不存在的 CI。main 测试包不重复调用 CI。新增标准库发布策略回归复用 plan 的既有测试入口。

- **Flutter**（`client/` 存在且改动涉及）：`scripts/run_flutter_tests.sh client`，`QA_REQUIRE_INTEGRATION=1`、`QA_REQUIRE_WIDGET_TESTS=1`，套在 `xvfb-run` 里跑 Linux integration。QA 日志和 `results.tsv` 作为 artifact 上传。
- **服务端**（`server/`）：`uv sync --frozen` → `uv run pytest -q` → `uv run ruff check .`
- **DSH 插件**（`dsh-plugin/`）：同上。插件的 `bb-auth-contract` 是 `../server/contract` 的路径依赖，所以 CI 里必须整份 checkout。

## 发布产物

| 产物 | runner | 文件名 |
| --- | --- | --- |
| Ubuntu / 通用 | ubuntu-latest | `bb_<ver>_amd64.deb`、`bb-<ver>-linux-x86_64.tar.gz` |
| Fedora / RHEL | ubuntu-latest（`apt install rpm`） | `bb-<ver>-1.x86_64.rpm` |
| Arch | `archlinux:latest` 容器 | `bb-bin-<ver>-1-x86_64.pkg.tar.zst` |
| Windows | windows-latest | `bb-<ver>-windows-x64.zip`（自带 LGPL FFmpeg + 许可/声明） |
| macOS | macos-latest | `bb-<ver>-macos.zip` |
| Android | ubuntu-latest + JDK 17 | `bb-<ver>-android-{arm64-v8a,armeabi-v7a,x86_64}.apk`、`bb-<ver>-android.aab` |

APK 按 CPU 架构拆分（`--split-per-abi`）：整包会把三个架构的 `libflutter.so` +
`libapp.so` 一起塞进去，54MB 里大约三分之二是目标设备用不到的那两个架构。单架构包
16–21MB，64 位设备装 `arm64-v8a`，老 32 位设备装 `armeabi-v7a`。上架仍然用 `.aab`。

打包脚本在 `scripts/ci/`，可以脱离 CI 单跑：

```bash
# deb + rpm（本机有 dpkg-deb / rpmbuild 才对应产出）
bash scripts/ci/package-linux.sh --bundle <flutter linux bundle 目录> \
  --out dist --version 0.2.0 --deb --rpm

# Arch 包（要在 Arch 环境，非 root 用户跑 makepkg）
bash scripts/ci/package-arch.sh --bundle <bundle> --out dist --version 0.2.0

# Windows：下载并校验固定源码 → MSYS2 自建最小 FFmpeg → 打包/检查/无系统 FFmpeg 冒烟
python scripts/ci/fetch_ffmpeg_sources.py --dest .ffmpeg-src
bash scripts/ci/build_ffmpeg_windows.sh --sources .ffmpeg-src --dest client/windows/ffmpeg
python scripts/ci/package_windows.py \
  --bundle client/build/windows/x64/runner/Release \
  --out dist --version 0.2.0 \
  --expected-ffmpeg-sha256 "$(grep '^ffmpeg_exe_sha256=' client/windows/ffmpeg/BUILD-MANIFEST.txt | cut -d= -f2)"
```

Windows 包不再依赖用户 PATH：`client/windows/CMakeLists.txt` 把暂存的
`windows/ffmpeg/` 安装进 release bundle（Release 缺失即失败），运行时
`resolveFfmpegExecutable()` 从应用目录解析。FFmpeg 由 `scripts/ci/ffmpeg_pins.py` 固定的源码
（FFmpeg 8.1.3 + zlib 1.3.1）在 CI 中自建，关闭 GPL/nonfree 与外部库；打包入口同时校验
`BUILD-MANIFEST.txt` 与构建输出的期望哈希，拒绝被改变/复用的旧暂存。固定版本/哈希/许可与
测试包说明见
`client/docs/dea477-windows-package.md`。PR 触发的 `Windows test package` 工作流会上传
`bb-windows-test-package` artifact；`release.yml` 的 Windows 作业复用同一脚本。

两个脚本都只打包不编译，`--bundle` 指向 `flutter build linux --release` 产出的那个 `bundle/` 目录。payload 统一装到 `/opt/bb/`，`/usr/bin/bb` 是指向它的相对符号链接，`/usr/share/applications/bb.desktop` 提供菜单入口。

## 已知缺口（不是 bug，是还没做）

1. **版本重置和升级边界**：本次 `0.2.0+1` → `0.0.1+2`，Android 构建号递增但展示版本降低；Linux 包是降级。未做真机覆盖安装，详见 [Release notes](RELEASE-NOTES.md)。
2. **`client/macos` 目录不存在**。macOS 作业第一次会在 runner 上 `flutter create --platforms=macos` 生成脚手架，然后打包。这条缝应该补上：生成一次、提交进仓库，否则每次构建都在赌 Flutter 模板版本。
3. **apk 用的是仓库自带的 debug keystore**（`client/android/debug.keystore`，密码 `android`）。可以安装，不能上架。真签名要改 `client/android/app/build.gradle.kts` 读 `key.properties`，并把 keystore 放 Secrets，属于产品侧改动。
4. **macOS 未签名未公证**。产物会被 Gatekeeper 拦，用户需要右键打开。公证需要 Apple Developer 账号（99 美元/年）和 `notarytool` 凭据。
5. **Windows 未做 Authenticode**，首次运行会弹 SmartScreen。EV 证书要钱，开源项目通常不签。
   Windows 包内置从固定源码自建的 LGPL FFmpeg（FFmpeg 8.1.3 + zlib 1.3.1；版本/哈希/许可/源码
   提供方式见 `client/docs/dea477-windows-package.md`）。若改变源码、configure 或引入外部库，
   必须重新核实许可、PE 依赖与源码提供义务，不能沿用旧结论。
6. **Arch 只出二进制包，没出 AUR 提交物**。AUR 只收 PKGBUILD 文本，要上 AUR 得单独建仓库、把 `PKGBUILD` + `.SRCINFO` 推上去。现在这个 `.pkg.tar.zst` 只能本地 `pacman -U` 装。
7. **服务端没有打包**。`server/` 目前是 `uv run` 起的 Python 服务，真要分发应该出 Docker 镜像或 systemd 单元，这条不在本次范围里。

## 需要的 Secrets

现在一个都不需要（全平台用默认凭据能出包）。将来补签名才需要：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ANDROID_STORE_PASSWORD`；macOS 侧 `MACOS_CERT_P12`、`MACOS_CERT_PASSWORD`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。
