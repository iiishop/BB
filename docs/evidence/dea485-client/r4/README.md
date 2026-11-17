# DEA-485 QA round 4 返工证据（R4 对账后的关系失效，Muse）

- 修前固定候选：`1e42fb7a44d5d7099126ca23bdc25ce74be4412f`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`50e6b51`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-4 附件原样保存于 `probes/dea485_round4_reconciliation_probe_test.dart`
  （SHA-256 `85e97c17cf9a87235e7a9587770b4b6a867e9461bc0597ef5b05eeb15a4d05ac`）
- 范围：只改 `client/` 与本证据目录；服务端仅作依赖；真实探针使用本机隔离 FastAPI（临时 DB/媒体、合成账号、端口 8769，采集后已停止）。

## 修前失败（1e42fb7，真实接收端 + 注入回包丢失）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8769 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round4_reconciliation_probe_test.dart
# exit 1：3 tests
#   confirmed  : success
#   reply_lost : failure  客户端关注流仍是 [作者] / 真实接收端 []（Expected Set[] / Actual 1 id）
#   not_sent   : success
```

原始 JSONL：`before/reconciliation-native.jsonl`。故障注入只发生在 gateway 返回边界
（服务端已提交，回包丢失）；写入、GET 与关注流全部走真实生成客户端与真实接收端。

## 修后通过（同一探针、同一接收端）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8769 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round4_reconciliation_probe_test.dart
# exit 0：3 success
```

原始 JSONL：`after/reconciliation-native.jsonl`。同一轮复跑此前全部客户端反例
（Q2/Q3/Q4/Q6、R2-A/B/C、R3 参数化两例）：**9/9 success，exit 0**（`after/prior-probes-native.jsonl`）；
既有真实 Profile/月份 API 测试：**1/1 success，exit 0**（`after/real-api-native.jsonl`）。

## 修复（同一关系失效机制的又一轮）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | 权威关系变化未统一经过 revision 失效：失败对账只写 `_states` 不递增 revision（R2-C 的对账恢复 → R4 的消费者失效） |
| **不变量** | 任何权威关系变化（确认写入、未知结果的 `get_follow` 对账、`follow.changed`）都必须让消费者失效；未变化（含重复 desired 状态）是真正的 no-op；失败提示与真实关系都要保留 |
| **状态所有者 / 全部入口** | `SpaceFollowStore`：`setFollowing`（成功分支、失败对账分支）、`_applyAuthoritative`、`ensureLoaded(force)`、`handleFollowChanged`；`SpaceController._onFollowRevision` 与其 active/parked/pending/游标失效 |
| **共同修复点** | 新增 `_applyAuthoritative(account, following, previous)`：确认写入与对账共用；`previous == null 或 previous != following` 时递增 revision。对账失败保持原值与 revision。R3 相邻用例改用真实关系变化，重复 desired 状态按契约不失效 |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r4_reconciliation_test.dart`（6 tests）：

- 单元：回包丢失且对账发现真实变化 → revision 前进、state 更新、error 保留；
  请求未送达 → state/revision 不变；对账本身失败 → 保持先前权威值；
  确认写入但期望状态未变 → 真正 no-op。
- 组件：回包丢失对账为已取关 → 活动关注流从首屏重取并变空（新请求带 scope=following、cursor=null）；
  请求未送达 → 作者保留、错误提示保留、不发生无谓重取。

R3 相邻用例 `all` 期间失效强制新查询改为真实关系变化（false→true）；此前 Q1–Q6/R2/R3 常规回归全部保持通过。

## 修后全量实跑（候选 `50e6b51`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +843 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- Android / Windows / 真实折叠屏、真实多设备 replay：NOT RUN。
- 未变组件（server 19 项、插件 122+lint、真实 Profile/月份边界）仍可按无变化组件复用，由 Sentinel 判定。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
