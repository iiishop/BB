# Linux Flutter 测试手册：无 Android 设备方案

## 首次环境探测

```bash
flutter doctor -v
flutter devices
command -v hyprctl || true
command -v grim || true
command -v jq || true
command -v Xvfb || true
```


## 统一三层测试：Multica 默认入口（已按上传 Skill 适配）

你上传的 `flutter-linux-android-setup` 在 2026-11-11 的示例项目里实测约 25 秒通过三层。原始文件保存在 `upstream/flutter-linux-android-setup/`，原样打包为 `skills/importable/flutter-linux-android-setup.skill`。本部署包另提供路径安全、不会覆盖显示环境变量的 `scripts/run_flutter_tests.sh`：

```bash
# 注意：这里的路径根据解压位置和实际 Flutter 项目根更换
bash /path/to/Multica_Social_Delivery_v4/scripts/run_flutter_tests.sh ~/Projects/social-platform/apps/mobile

# 登录、消息、Space 等关键用户流程必须有 integration_test，否则失败
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  bash /path/to/Multica_Social_Delivery_v4/scripts/run_flutter_tests.sh ~/Projects/social-platform/apps/mobile

# 只有经批准、确有必要使用用户级 systemd scope 的环境才设置：
QA_USE_SYSTEMD_SCOPE=1 QA_REQUIRE_INTEGRATION=1 \
  bash /path/to/Multica_Social_Delivery_v4/scripts/run_flutter_tests.sh ~/Projects/social-platform/apps/mobile
```

输出 `LOG_DIR` 与 `results.tsv`，逐级 PASS/FAIL/NOT_RUN。0 表示已执行阶段全部通过，但**可能跳过缺少的 test/ 或 integration_test/**；强制策略使用 `QA_REQUIRE_*`。

统一脚本只完成 Analyze → Unit/Widget/Golden（若存在）→ Linux Integration。Linux 桌面启动截图、Android APK build、后端/MCP/DSH E2E 需要在独立关卡执行。不要把 Golden 的 `--update-goldens` 当作验收命令。

## 运行测试

进入 `apps/mobile`（或实际 Flutter 项目根）：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
# 仅当项目实际设置了 golden tag：
flutter test --tags golden
# Linux 桌面依赖和编译配置就绪后：
flutter build linux --release
# 仅当 integration_test/<file>.dart 确实存在且 Linux device 可用：
flutter test integration_test/app_test.dart -d linux
# 仅 Android SDK/JDK 已配置：
flutter build apk --debug
```

**避免把不适用命令的失败误称为功能缺陷：** `flutter test --tags golden` 在没有 tag 时不会自动发现所有 Golden 测试；项目应统一 tag 或目录策略。

## Golden 字体

Flutter test 环境可能用 Ahem 字体，让字形成为方块。Golden 可检查布局/差异，但不是“真实文案审美”。要检查真实字体需在 setUpAll 加载获授权的确定 `.ttf`，使用 Flutter `FontLoader`；将字体、Flutter 版本、DPR、测试操作系统与 baselines 锁定。不要把真实付费字体放进本包。

## 截图

Linux 实际渲染，优先 Hyprland `hyprctl clients -j` 精确按**本次启动进程 PID**选择窗口，`grim -g` 捕获该窗口区域。参考脚本 `scripts/capture_hyprland.sh`。该脚本要求你提供已编译 runner 的准确路径，不自动全屏截图，也不会 `pkill` 共享进程。

若无 Hyprland 但有 Xvfb，可以建立虚拟显示并用适配的截图工具/窗口管理器；需自行验证依赖与截图真实性，不得称为 Android 运行。

## 注意

- 桌面窗口接近手机比例不代表手机系统安全区/键盘/通知/权限/摄像头已测。
- 真实 Flutter UI 需要 Agent 实际打开/检查截图；仅生成文件不算视觉 review。
- 测试前记录 git commit；测试后附 stdout/stderr、exit code、截图文件实际路径。
- 不使用 `pkill -f`；`pkill -x` 虽精准匹配程序名，仍可能误伤同名进程，建议 PID 专属清理。
