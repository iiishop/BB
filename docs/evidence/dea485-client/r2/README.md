# DEA-485 QA round 2 返工证据（R2-A/R2-B/R2-C，Muse）

- 修前固定候选：`90a79b8f094d66be303cda67a97f24a110cddb6c`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`55a8683`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-2 附件原样保存于 `probes/dea485_round2_mechanism_probe_test.dart`
  （SHA-256 `fa35974d2c8508a009d312bfcffc789993af350d52347ef1ef11a28a58880ba4`）
- 范围：只改 `client/` 与本证据目录；服务端仅作依赖；未改公共 scripts/CI；Q5 不在本轮。

## 修前失败（90a79b8，原样探针）

```bash
cd client
flutter test --no-pub --reporter=json .qa-artifacts/dea485_round2_mechanism_probe_test.dart
# exit 1：3 tests
#   R2-A widget：reporter error（原始 TestFailure，wrapper 限制）
#   R2-B：failure  Expected: null / Actual: '暂时无法连接服务器，请稍后重试'
#   R2-C：failure  Expected: false / Actual: <null>
```

原始 JSONL：`before/mechanism-native.jsonl`。R2-A 在上一候选 `b6becc4` 通过、在本基线失败，
由 Q4 修复引入；R2-B/R2-C 在两个基线均失败、本轮首次覆盖。

## 修后通过（同一探针）

```bash
flutter test --no-pub --reporter=json .qa-artifacts/dea485_round2_mechanism_probe_test.dart
# exit 0：3 success
```

原始 JSONL：`after/mechanism-native.jsonl`。同一轮复跑上一轮原缺陷探针：
`flutter test --no-pub --reporter=json .qa-artifacts/dea485_review_probe_test.dart
.qa-artifacts/dea485_identity_review_probe_test.dart`（Q2/Q3/Q4/Q6）→ **4/4 success，exit 0**，
原始 JSONL 在 `after/original-probes-native.jsonl`。

真实隔离后端（临时 DB/媒体目录、合成账号、端口 8768，采集后已停止）：
`BB_SPACE_API_BASE=... flutter test --no-pub --reporter=json test/space_profile_real_api_test.dart`
→ **1 success，exit 0**（`after/real-native.jsonl`）。

## 修复

| ID | 不变量 | 状态所有者 / 全部入口 | 修复 |
| --- | --- | --- | --- |
| R2-A | 已完成且可见的模式不能被在途请求变成永久空态 | `SpaceController`：`switchScope` / `_parkScope` / `_startScopeLoad` / `_loadFeedFirst` / `resetSession` | parked 快照记录 `loaded`（是否完成过首屏）。未完成的缓存恢复时走 `_startScopeLoad` 重新取首屏；旧请求仍由 generation 拒绝 |
| R2-B | 当前可见模式不显示被放弃请求的错误 | `SpaceController`：`_loadFeedFirst` 的 success/AuthFailure/通用 catch；`loadMore` 的 catch/finally；`refresh` 结束时的 pending follow reload | 所有 catch 入口在写 `phase/feedError/offline` 前统一校验 `generation == _feedGeneration && scope == requested`；当前请求的错误仍照常显示 |
| R2-C | 已知关注目标最终必须落到权威状态且控件可用 | `SpaceFollowStore`：`seedFromPosts` / `ensureLoaded` / `setFollowing` / `handleFollowChanged` | 增加 `_knownTargets`（不被失效清空）与 `_reloadRequested` 合并重读：失效强制重读；在途读被新 revision 淘汰时，若目标仍未知则自动补一次权威读；写入已设置权威值时不再多发读 |

三者共用同一原则：**拒绝旧结果，同时完成合法的在途工作**，而不是只清标志或特判单个入口。

## 并入默认回归（`test/` 常规收集）

`client/test/space_r2_regression_test.dart`（7 tests，全部默认执行）：

- R2-A 原场景；相邻合法路径：已完成的 parked 快照恢复不再重复请求首屏。
- R2-B 原场景；相邻合法路径：当前关注流首屏真实失败仍显示错误与 `error` 阶段。
- R2-C 原场景（连续两次失效、首次读在途）；相邻合法路径：单次失效只重读一次并得到权威值；
  写入与在途读竞争时写入胜出且不额外重读。

上一轮 Q1–Q4/Q6 的常规回归（`space_feed_scope_test.dart`、`space_profile_*`）保持通过。

## 修后全量实跑（候选 `55a8683`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +833 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- Android / Windows / 真实折叠屏：NOT RUN（与上一轮相同）。
- 真实多设备 follow replay、所有刷新/关注/写失败重叠组合、pending 计数与嵌套返回组合：未独立执行。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；仍由 Orion 集成唯一候选后再走 automated_qa。
