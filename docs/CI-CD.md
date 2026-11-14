# CI/CD

两套流水线：PR 门禁（`ci.yml`）和发布打包（`release.yml`）。都用 GitHub 官方 runner，不自建。

## 触发条件

| 工作流 | 触发 | 结果 |
| --- | --- | --- |
| `ci.yml` | PR（opened / synchronize / reopened / ready_for_review）、push 到 main、手动 | 只跑改动的子系统；三层 QA + 两套 pytest |
| `release.yml` | push 到 main | 全平台构建，产物留在 workflow artifact（14 天） |
| `release.yml` | 打 `v*` tag | 同样的构建，另建 GitHub Release 并附 `SHA256SUMS`，最后回下载校验 |
| `release.yml` | 手动，勾 `publish` | 同上，tag 用 `v<pubspec 版本>` |

版本号只有一处来源：`client/pubspec.yaml` 的 `version`。打 tag 时如果 tag 名跟它对不上，`meta` 作业直接失败，不会静默发出一版错版本。

## PR 门禁做什么

`plan` 先判断三个子系统在不在、这次改动涉不涉及，缺目录的整段跳过（仓库现在 main 上只有文档和 `scripts/`，所以会出现“全部跳过”的绿色）。

- **Flutter**（`client/` 存在且改动涉及）：`scripts/run_flutter_tests.sh client`，`QA_REQUIRE_INTEGRATION=1`、`QA_REQUIRE_WIDGET_TESTS=1`，套在 `xvfb-run` 里跑 Linux integration。QA 日志和 `results.tsv` 作为 artifact 上传。
- **服务端**（`server/`）：`uv sync --frozen` → `uv run pytest -q` → `uv run ruff check .`
- **DSH 插件**（`dsh-plugin/`）：同上。插件的 `bb-auth-contract` 是 `../server/contract` 的路径依赖，所以 CI 里必须整份 checkout。

## 发布产物

| 产物 | runner | 文件名 |
| --- | --- | --- |
| Ubuntu / 通用 | ubuntu-latest | `bb_<ver>_amd64.deb`、`bb-<ver>-linux-x86_64.tar.gz` |
| Fedora / RHEL | ubuntu-latest（`apt install rpm`） | `bb-<ver>-1.x86_64.rpm` |
| Arch | `archlinux:latest` 容器 | `bb-bin-<ver>-1-x86_64.pkg.tar.zst` |
| Windows | windows-latest | `bb-<ver>-windows-x64.zip` |
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
```

两个脚本都只打包不编译，`--bundle` 指向 `flutter build linux --release` 产出的那个 `bundle/` 目录。payload 统一装到 `/opt/bb/`，`/usr/bin/bb` 是指向它的相对符号链接，`/usr/share/applications/bb.desktop` 提供菜单入口。

## 已知缺口（不是 bug，是还没做）

1. **main 上还没有 `client/`、`server/`、`dsh-plugin/`**。三个 STEP 都还在 `agent/*` 分支上，合并前所有构建作业都会被跳过。流水线本身能跑，但没有东西可构建。
2. **`client/macos` 目录不存在**。macOS 作业第一次会在 runner 上 `flutter create --platforms=macos` 生成脚手架，然后打包。这条缝应该补上：生成一次、提交进仓库，否则每次构建都在赌 Flutter 模板版本。
3. **apk 用的是仓库自带的 debug keystore**（`client/android/debug.keystore`，密码 `android`）。可以安装，不能上架。真签名要改 `client/android/app/build.gradle.kts` 读 `key.properties`，并把 keystore 放 Secrets，属于产品侧改动。
4. **macOS 未签名未公证**。产物会被 Gatekeeper 拦，用户需要右键打开。公证需要 Apple Developer 账号（99 美元/年）和 `notarytool` 凭据。
5. **Windows 未做 Authenticode**，首次运行会弹 SmartScreen。EV 证书要钱，开源项目通常不签。
6. **Arch 只出二进制包，没出 AUR 提交物**。AUR 只收 PKGBUILD 文本，要上 AUR 得单独建仓库、把 `PKGBUILD` + `.SRCINFO` 推上去。现在这个 `.pkg.tar.zst` 只能本地 `pacman -U` 装。
7. **服务端没有打包**。`server/` 目前是 `uv run` 起的 Python 服务，真要分发应该出 Docker 镜像或 systemd 单元，这条不在本次范围里。

## 需要的 Secrets

现在一个都不需要（全平台用默认凭据能出包）。将来补签名才需要：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ANDROID_STORE_PASSWORD`；macOS 侧 `MACOS_CERT_P12`、`MACOS_CERT_PASSWORD`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。
