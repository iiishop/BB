# DEA-485 QA round 7 返工证据（R7 跨目标失败反馈，Muse）

- 修前固定候选：`a4785f688579f1fccf3a9e76b23a20cd4bf8455e`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`5301aae`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-7 附件原样保存于 `probes/`：
  - `dea485_round7_failure_feedback_probe_test.dart` — SHA-256 `9215b92b3d5dbe574d54fe27d5ddcd4cfedee4222bf0e6da702861967d8d5c63`
  - `dea485_round7_feedback_ui_probe_test.dart` — SHA-256 `475dd623b7f5ad98b985a448337f773f08720585acf75816c06654de5b7b5835`
  - `dea485_round7_exhaustion_probe_test.dart` — SHA-256 `fdac5982c34bd77f67157a05b49bb1c72c5281e95482254cb6e90aee59d7ddd7`
- 范围：只改 `client/` 与本证据目录；真实探针使用本机隔离 FastAPI（临时 DB/媒体、合成账号、端口 8772，采集后已停止）。

## 修前失败（a4785f6，真实接收端 + 双作者卡片）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8772 flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_round7_failure_feedback_probe_test.dart \
  .qa-artifacts/dea485_round7_feedback_ui_probe_test.dart \
  .qa-artifacts/dea485_round7_exhaustion_probe_test.dart
# exit 1：8 tests，5 pass / 2 assertion failure / 1 widget TestFailure（reporter error）
#   failed write across target: concurrent=true  （A 的错误被 B 的成功清空）
#   failed card unfollow UI:    concurrent=true   （无失败提示）
#   settlement fencing lostReply=true races=2     （同一共享 error 被其他目标写入清空）
```

原始 JSONL：`before/feedback-native.jsonl`。故障只注入 gateway 边界；真实注册账号、实际
FastAPI、事件与生产 store。sentinel 报告列出的 1 pass／1 fail 针对反馈探针；耗尽探针本机
在 races=2/lostReply=true 也命中同一根因，修复后一并转绿。

## 修后通过（同一探针、同一接收端）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8772 flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_round7_failure_feedback_probe_test.dart \
  .qa-artifacts/dea485_round7_feedback_ui_probe_test.dart \
  .qa-artifacts/dea485_round7_exhaustion_probe_test.dart
# exit 0：8 success（4 耗尽 + 2 跨目标反馈 + 2 双作者卡片提示）
```

原始 JSONL：`after/feedback-native.jsonl`。同轮复跑此前全部客户端反例
（R6 3、R5 3、R4 3、Q2/Q3/Q4/Q6 4、R2 3、R3 2）：**18/18 success，exit 0**
（`after/prior-probes-native.jsonl`）；既有真实 Profile/月份 API 测试 **1/1 success**
（`after/real-api-native.jsonl`）。

## 修复（失败反馈归属操作／目标）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | 失败反馈是全局共享 `error`：另一目标的成功写入/读取会清空它，调用方拿不到本次操作的失败（R6 未结算反馈 → R7 反馈归属） |
| **不变量** | 失败反馈属于产生它的目标/操作，不能被其他目标的成功抹掉；成功/刷新只清理该目标自己的错误；未结算/对账/写入失败仍必须明确反馈 |
| **状态所有者 / 全部入口** | `SpaceFollowStore`：`_errors` + `errorFor(account)` + `error`（兼容单目标）、`setFollowing` 开始/成功/失败、`ensureLoaded` 成功、`_settleWriteResult`、`handleFollowChanged` 后的强制读；`toggleSpaceFollow` 的失败提示读取 |
| **共同修复点** | 错误按目标存储；操作开始只清本目标；成功/刷新只清本目标；失败写入/对账/结算失败按目标记录；UI 调用方用 `errorFor(account)`（回退 `error`）展示本次操作反馈 |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r7_feedback_test.dart`（3 tests）：

- 单元：A 未发送失败并等待对账时，B 成功关注 → A 的 `errorFor` 保持非空、B 的为空；
  A 返回 false、状态保留；A 的刷新只清 A 自己的错误。
- 单元：无并发时 A 仍报告自身失败。
- 组件：双作者卡片；A 取关失败（对账挂起）期间 B 关注成功 → 释放后现有 UI 显示 A 的失败提示，
  两卡片关系分别正确。

R6/R5/R4/R3/R2/Q 系列常规回归全部保持通过。

## 修后全量实跑（候选 `5301aae`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +853 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- 其他跨作者读/多错误组合、Android/Windows/真实折叠屏、物理多设备、实际丢包/断网、
  DSH 安装/模型链路：NOT RUN。
- 未变组件（server 19 项、插件 122+lint、真实 Profile/月份边界）按无变化组件复用，由 Sentinel 判定。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
