# QA Test Matrix — 当前无模拟器/真机

| Category | Command / Action | GUI | Expected label | Limitation |
|---|---|---|---|---|
| Dart formatting | `dart format --output=none --set-exit-if-changed .` | 否 | PASS/FAIL | 不等于代码逻辑正确 |
| Flutter analyzer | `flutter analyze` | 否 | PASS/FAIL | 不等于运行正常 |
| Unit / Widget | `flutter test` | 否 | PASS/FAIL | 测试渲染环境，不是桌面/手机真实屏幕 |
| Golden | 项目 golden 用例 / `flutter test --tags golden`（仅项目实际使用 tag） | 否 | PASS/FAIL/NOT RUN | 默认 Ahem 字体黑方块；参考基线和字体版本固定 |
| Linux Desktop build | `flutter build linux --release` | 不要求 GUI | PASS/FAIL | 编译成功不等于真实渲染通过 |
| Linux Desktop screenshot | 启动 Linux runner + hyprctl/grim 截图 | 需要桌面/虚拟显示 | PASS/FAIL/NOT RUN | 必须实际检查截图；不代表 Android |
| Linux Integration | 已验证入口 `QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh <project>` | 需要 Linux desktop 支持 | PASS/FAIL/NOT RUN | 示例工程曾实测通过；新 commit 仍需重测；缺测试目录严格模式失败 |
| Android Build | `flutter build apk --debug` | 不需要模拟器/真机，但需要 SDK | PASS/FAIL/NOT RUN | 不证明 Android 运行/权限/性能 |
| Backend Unit/API | `pytest` / 项目 CI | 否 | PASS/FAIL | 用测试库；覆盖权限/错误 |
| Bot/MCP | mock+真实测试 Runtime 受控工具用例 | 否/按场景 | PASS/FAIL/NOT RUN | 不比对固定 AI 文本 |
| Android device runtime | adb+真机 | 真机 | **NOT RUN** | 没设备不可用，后续你人工验收 |

## 必测的用户故事风险

- 账号注册、登录、错密码、权限隔离。
- Chat：发送成功/失败、重复请求、断线重连、历史一致、长文字、图片失败及授权。
- Space：AI / 真人的作者身份、时间排序、发布权限与动态读取。
- MCP：工具最小权限与 API 业务逻辑一致；Bot 重复唤醒不重复发送。
- Linux UI：360×800 / 412×915 等**逻辑视口近似**仅在可调窗口时；不替代 Android Insets、软键盘、DPI、帧率测试。

结论：测试证明的是它真正跑过的环境；任何从 Linux 推断 Android UI 完全正确的结论都不合格。

**三层统一 runner：** `/scripts/run_flutter_tests.sh` 将 analyze、flutter test、Linux integration-test 分别记录到 `results.tsv`。脚本成功不证明项目包含 Golden 用例，也不包含真实 UI 截图或 Android 运行验收。
