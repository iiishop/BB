# DEA-485 QA round 3 返工证据（R3 关系失效后的关注流缓存，Muse）

- 修前固定候选：`63e3b6aeac53d4b4b3c7784e8060432b30a3ac10`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`0130053`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-3 附件原样保存于 `probes/dea485_round3_follow_cache_probe_test.dart`
  （SHA-256 `519823e82572145314f616a272373afae5dca245350e41a522358c3e5fb217e2`）
- 范围：只改 `client/` 与本证据目录；服务端仅作依赖；未改公共 scripts/CI；Q5 仍不在本轮。

## 修前失败（63e3b6a，原样参数化探针）

```bash
cd client
flutter test --no-pub --reporter=json .qa-artifacts/dea485_round3_follow_cache_probe_test.dart
# exit 1：2 tests
#   ordinary unfollow（不切模式）：success
#   unfollow + all→following 往返：error（原始 widget TestFailure 被 reporter 包装）
```

原始 JSONL：`before/follow-cache-native.jsonl`。同一数据不往返时能正确变空，往返后恢复旧缓存，
属于本轮首次覆盖的既有关系失效/缓存恢复缺陷（R2 原反例仍绿）。

## 修后通过（同一探针）

```bash
flutter test --no-pub --reporter=json .qa-artifacts/dea485_round3_follow_cache_probe_test.dart
# exit 0：2 success
```

原始 JSONL：`after/follow-cache-native.jsonl`。同轮复跑此前全部客户端反例（Q2/Q3/Q4/Q6、
R2-A/R2-B/R2-C）：**7/7 success，exit 0**（`after/prior-probes-native.jsonl`）。

## 修复（同一机制第三次返工，按不变量处理）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | `space-feed-scope-cache` 的“加载完成”与“关系修订有效”混为一个 `loaded` 标志（Q2/Q4 → R2-A/B/C → R3） |
| **不变量** | 可见/可恢复的缓存必须同时满足“完成过首屏”且“属于当前 follow revision”；拒绝旧结果后，当前有效查询必须仍被完成 |
| **状态所有者 / 全部入口** | `SpaceController`：`_feedLoaded` + 新增 `_feedFollowRevision`；`_loadFeedFirst`（成功与 catch）、`loadMore`（成功与 catch）、`refresh`、`switchScope`、`_parkScope`、`_startScopeLoad`、`resetSession`、`_onFollowRevision`；快照 `_FeedSnapshot.loaded/followRevision`。`SpaceFollowStore.revision` 是唯一关系版本源 |
| **共同修复点** | 快照记录加载时的 follow revision；`_onFollowRevision`（活动关注流）清 `loaded`、递增 feed generation、释放 `loadingMore`，刷新中排队、否则立刻重取；首屏/续页响应在应用前校验请求发起时的 revision；`switchScope` 只在快照 `loaded` 且 revision 等于当前值时恢复，否则 `_startScopeLoad` 重取（同时让被 generation 拒绝的旧查询由新查询补上） |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r3_regression_test.dart`（4 tests）：

- R3 参数化两例：不切模式取关 → 空态；取关 + all→following 往返（空首屏延迟返回）→ 不得复活
  Bob 的说说，最终空态。
- 相邻合法路径：无关系变化的已完成关注流缓存恢复不重复请求（保留正常缓存/位置）；
  `all` 模式期间关系失效 → 切回 following 必须发新的首屏查询并显示新结果。

此前 Q1–Q6、R2-A/B/C 的常规回归同样保持通过。

## 修后全量实跑（候选 `0130053`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +837 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- 本轮未重跑真实隔离后端 API：该路径（`SpaceProfileAdapter` / 月份续页 / follow 读写）本轮未改，
  上一轮 Sentinel 已独立通过，可按无变化组件复用；本轮控制器改动的真实设备组合未验证。
- Android / Windows / 真实折叠屏、真实多设备 follow replay：NOT RUN。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
