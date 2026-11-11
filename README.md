# BB — Social Platform

Flutter 客户端 + FastAPI 服务端的私人社交平台。三个一等模块：Profile / Chat / Space。

本仓库是 Multica Squad `Social Platform Delivery` 的交付仓库。

## 目录

```
apps/mobile/          Flutter 客户端（Muse 负责）
services/api/         FastAPI + SQLite 业务服务（Forge 负责）
services/bot/         DSH Bot Runtime 事件处理（Forge 负责）
packages/contracts/   REST/WS/MCP 共享契约
docs/                 项目上下文、工程红线、接口契约种子、QA 模板
scripts/              统一 QA runner
```

目录尚未创建时，由接手的 Agent 按任务需要初始化，不要提前塞空壳。

## QA

```bash
bash scripts/run_flutter_tests.sh apps/mobile                       # 常规
QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh apps/mobile   # 端到端任务必须
```

`0` = 所有已执行阶段通过；缺用例在严格模式下记 FAIL，不会被当成 PASS。逐阶段结果写进 `results.tsv`。
无 Android 模拟器/真机：Android 相关一律 NOT RUN，Linux 截图不等于 Android 验证。

## 团队与流程

Orion（调度/契约）· Muse（Flutter 前端）· Forge（后端）· Sentinel（独立 QA）· Owner（人工验收）。
状态流：Backlog → Ready → In Progress → Automated QA → Owner Review → Done，另有 Blocked。
合并 main、正式发布、父需求 Done 只有 Owner 能批准。
