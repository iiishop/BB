# DEA-485 QA round 5 返工证据（R5 写入结果归属，Muse）

- 修前固定候选：`9a2600509ee6d9e7e0a688c6e0f609f5df035b35`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`08ec77a`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-5 附件原样保存于 `probes/dea485_round5_authority_probe_test.dart`
  （SHA-256 `d1241774c23128632b0d8b0d44b129152b4c1fb16dc5fb03bf2c82c8b55bee96`）
- 范围：只改 `client/` 与本证据目录；真实探针使用本机隔离 FastAPI（临时 DB/媒体、合成账号、端口 8770，采集后已停止）。

## 修前失败（9a26005，真实接收端 + 事件重放）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8770 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round5_authority_probe_test.dart
# exit 1：3 tests
#   older ack            : failure  旧 ACK(false) 在事件 GET(true) 之后到达，共享关系回退 false
#   older reconciliation : failure  旧对账 GET(false) 返回后回退 false
#   accepted_later        : success  请求先发起、服务端在事件之后才接受，最终 false 正常生效
```

原始 JSONL：`before/authority-native.jsonl`。延迟/丢回包只注入在 gateway 边界；写入、GET、
关注流与事件均使用真实生成客户端与真实接收端，未冒称物理丢包/多设备。

## 修后通过（同一探针、同一接收端）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8770 \
  flutter test --no-pub --reporter=json .qa-artifacts/dea485_round5_authority_probe_test.dart
# exit 0：3 success
```

原始 JSONL：`after/authority-native.jsonl`。同轮复跑此前全部客户端反例
（R4 真实对账 3 条、Q2/Q3/Q4/Q6 4 条、R2 3 条、R3 2 条）：**12/12 success，exit 0**
（`after/prior-probes-native.jsonl`）；既有真实 Profile/月份 API 测试 **1/1 success**
（`after/real-api-native.jsonl`）。

## 修复（关系权威归属机制）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | 写入结果缺少归属（request revision）：旧 ACK / 旧对账结果在更新权威事实之后到达仍直接写入（R2-C 对账恢复 → R4 对账失效 → R5 结果归属） |
| **不变量** | 已观察到的更新权威事实不能被更旧的结果回滚；服务端较晚接受的合法写入仍必须完成；真实失败提示与该次请求的错误语义保留 |
| **状态所有者 / 全部入口** | `SpaceFollowStore.setFollowing`（成功 ACK 与失败对账）、新增 `_settleWriteResult` / `_readLatestAuthoritative`、`_applyAuthoritative`、`ensureLoaded(force)`、`handleFollowChanged`；`SpaceController._onFollowRevision` 及其 active/parked/pending/游标失效 |
| **共同修复点** | 请求发起时记录 revision；结果到达时若期间已应用更新事实，则不直接写回，而是在结果到达后按 fencing 重读接收端（读期间又有新事实则重试，最多 3 次）；重读发现真实变化仍递增 revision 使消费者失效。结果与事件无法仅凭交付顺序排序，因此用“结果到达后再读”区分 stale 与 accepted-later |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r5_authority_test.dart`（4 tests）：

- 单元：stale ACK（服务端已先提交 false，随后事件 true，旧 ACK 到达）→ 保持 true；
  stale 对账（旧 `get_follow(false)` 被暂缓，事件 true 先完成）→ 保持 true 且错误提示保留；
  accepted-later（请求先发起、服务端在事件后提交 false）→ 最终 false。
- 组件：accepted-later 后共享状态变化触发关注流失效，列表从首屏重取并变空。

此前 R4 的 confirmed/reply_lost/not_sent、R3/R2/Q 系列常规回归全部保持通过。

## 修后全量实跑（候选 `08ec77a`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +847 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- Android / Windows / 真实折叠屏、物理多设备、真实丢包/断网：NOT RUN。
- 未变组件（server 19 项、插件 122+lint、真实 Profile/月份边界）按无变化组件复用，由 Sentinel 判定。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
