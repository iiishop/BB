# DEA-485 QA round 6 返工证据（R6 恢复未结算的静默成功，Muse）

- 修前固定候选：`b5d1d1b862b44cb852807d2a8eb72038d47c3beb`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`c6c7c28`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-6 附件原样保存于 `probes/dea485_round6_recovery_probe_test.dart`
  （SHA-256 `aef35f02ab1afeb784959248c00404ea3f310605667180e27b1b792f0422a7dc`）
- 范围：只改 `client/` 与本证据目录；真实探针使用本机隔离 FastAPI（临时 DB/媒体、合成账号、端口 8771，采集后已停止）。

## 修前失败（b5d1d1b，真实接收端 + 事件重放）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8771 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round6_recovery_probe_test.dart
# exit 1：3 tests
#   later_ok            : success
#   later_unavailable   : failure  applied=true / error=null，而 store=true 与 receiver=false 不一致
#   earlier_unavailable : success（旧结果保护仍生效，最终一致）
```

原始 JSONL：`before/recovery-native.jsonl`。故障只注入 gateway 边界；API、提交、事件与前置
GET 均真实。失败为原生断言，无 error/skip。

## 修后通过（同一探针、同一接收端）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8771 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round6_recovery_probe_test.dart
# exit 0：3 success
```

原始 JSONL：`after/recovery-native.jsonl`。同轮复跑此前全部客户端反例
（R5 3 条、R4 3 条、Q2/Q3/Q4/Q6 4 条、R2 3 条、R3 2 条）：**15/15 success，exit 0**
（`after/prior-probes-native.jsonl`）；既有真实 Profile/月份 API 测试 **1/1 success**
（`after/real-api-native.jsonl`）。

## 修复（恢复终态必须明确“已结算／未完成”）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | 写入结果的恢复终态未反馈：`_settleWriteResult` 返回 void，`_readLatestAuthoritative` 吞掉读错误后按成功返回（R5 结果归属 → R6 恢复结算反馈） |
| **不变量** | 每次写入必须给出“已结算／未完成”的明确结果，并与调用方提示一致：未完成时 `applied=false` 且 `error != null`；已结算时保留旧结果保护、accepted-later、no-op 与真实失败语义 |
| **状态所有者 / 全部入口** | `SpaceFollowStore.setFollowing` 成功/失败分支、`_settleWriteResult`、`_readLatestAuthoritative`、`_applyAuthoritative`、`ensureLoaded(force)`、`handleFollowChanged`；`SpaceController._onFollowRevision` 与消费者失效 |
| **共同修复点** | `_settleWriteResult` 返回是否已结算；重读失败返回具体错误文本，三次 fencing 重试耗尽返回统一未确认文案；未结算时保留最后已知关系但 `setFollowing` 返回 false 且保证 `error` 非空（UI 的失败提示条件）；已结算路径语义不变 |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r6_settlement_test.dart`（3 tests）：

- 单元：更新事实已同步、写入随后提交但最新重读不可用 → 返回 false、`error != null`、
  保留最后已知关系；读恢复后经既有失效路径结算到接收端真实值并清除错误。
- 单元：重读可用时静默结算成功（applied=true，无错误）。
- 组件：通过真实卡片控件取关，命中同一条不可用时序 → 现有 UI 显示失败提示，
  关系保留最后已知值。

三次 fencing 重试耗尽出口未实跑（与读失败共用同一未结算返回与提示），按源码核对记录；
R5/R4/R3/R2/Q 系列常规回归全部保持通过。

## 修后全量实跑（候选 `c6c7c28`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +850 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- 三次 fencing 重试耗尽出口、Android/Windows/真实折叠屏、物理多设备、实际丢包/断网：NOT RUN。
- 未变组件（server 19 项、插件 122+lint、真实 Profile/月份边界）按无变化组件复用，由 Sentinel 判定。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
