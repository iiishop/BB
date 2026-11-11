# 上传 Skill 审核与集成记录

来源：用户上传 `flutter-linux-android-setup(1).zip`（2026-11-12）。原始 `SKILL.md` 与 `run_flutter_tests.sh` **字节级保持不变**，收录在 `upstream/flutter-linux-android-setup/`。

## 原版通过事实（用户提供）
- 示例项目 `flutter analyze` + `flutter test` + `integration_test -d linux` 约 25 秒全通过；这是用户现有机器上的记录，不是我们在本次生成环境重测。
- 原始脚本 0=已执行测试都成功、1=至少一项失败；没有 `integration_test/` 时跳过，**不等于集成测试通过**。

## 适配差异
- Multica 没有稳定的 `~/.hermes/skills/...` 路径，因此默认使用部署包/项目仓库中的脚本绝对路径。
- 原脚本默认覆盖 `WAYLAND_DISPLAY=wayland-1` / `DISPLAY=:0` / `XDG_RUNTIME_DIR=/run/user/1000`；v4 版本继承当前环境，避免错误屏幕会话。
- 原脚本始终尝试 `systemd-run --user --scope`；v4 只有显式 `QA_USE_SYSTEMD_SCOPE=1` 才使用，且通过安全的 shell 位置参数传递工程路径。其使用必须符合当前 Agent 执行资源政策。
- v4 逐阶段输出 `results.tsv`，并提供 `QA_REQUIRE_INTEGRATION=1`/`QA_REQUIRE_WIDGET_TESTS=1`，缺失测试时 FAIL，而非假成功。
- 不能将 `flutter test --update-goldens` 视为测试成功；它更新基准，更新前需审查。
- 原 SKILL 中某些环境安装结论（例如 CLI 更替、具体 SDK/版本、JDK 问题）是机器特定记录，不应在其他机器上作为通用事实；先实际探测工具可用性。
- 原 SKILL 的 `pkill -x` 比 `pkill -f` 精确，但仍可能杀死其他同名程序。优先 PID 精确回收。

## 使用边界
- v4 Runner 不做 Android 真机运行，不做真实渲染截图，不做 FastAPI/MCP/DSH 业务联调，这些需要另外运行并独立报告。
- Golden 是 `flutter test` 运行的用例之一（存在时），不能仅凭单个 `flutter test` PASS 声称存在或覆盖了 Golden。
