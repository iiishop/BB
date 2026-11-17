# DEA-485 Q1–Q4/Q6 返工证据（Muse）

- 修前候选：`b6becc4f143b2489ddc04f12a8ec0af1e20f8a86`（Sentinel 独立 QA 固定候选）
- 修后候选：`7cfed39`（修复提交，分支 `agent/muse/bac7692aa6f7`）
- 探针来源：Sentinel QA 附件 `dea485-sentinel-qa.zip`（本目录 `probes/` 原样保存）
- 范围：只改 `client/` 与本证据目录；服务端仅作依赖，未修改；Q5（MCP 暴露边界）不属于本返工。

## 修前失败（原样使用 Sentinel 探针）

探针放在 `client/.qa-artifacts/`，用 Sentinel 给出的命令执行（`--no-pub --reporter=json`）：

```bash
flutter test --no-pub --reporter=json .qa-artifacts/dea485_review_probe_test.dart
# 修前 exit 1：3 tests / failure 2 / error 1（Q2 reporter 包装 TestFailure）
flutter test --no-pub --reporter=json .qa-artifacts/dea485_identity_review_probe_test.dart
# 修前 exit 1：1 test / error 1（Q6）
BB_SPACE_API_BASE=http://127.0.0.1:8767 \
  flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_real_review_probe_test.dart test/space_profile_real_api_test.dart
# 修前 exit 1：2 tests / failure 1（Q1）/ success 1
```

原始 JSONL：`before/review-native.jsonl`、`before/identity-native.jsonl`、`before/real-native.jsonl`。

## 修后通过（同一探针、同一命令）

```bash
flutter test --no-pub --reporter=json .qa-artifacts/dea485_review_probe_test.dart
# 修后 exit 0：3 success
flutter test --no-pub --reporter=json .qa-artifacts/dea485_identity_review_probe_test.dart
# 修后 exit 0：1 success
BB_SPACE_API_BASE=http://127.0.0.1:8767 \
  flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_real_review_probe_test.dart test/space_profile_real_api_test.dart
# 修后 exit 0：2 success（Q1 真实续页 + 既有真实双账号路径）
```

原始 JSONL：`after/review-native.jsonl`、`after/identity-native.jsonl`、`after/real-native.jsonl`。
真实探针使用临时 DB/媒体目录的隔离服务端（仅合成账号），采集后已停止进程。

探针文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `probes/dea485_review_probe_test.dart` | `4a7a52d79bb3ab7aa20d26fd58294eafa7c973b091dffd6c82067cfb8d387f87` |
| `probes/dea485_identity_review_probe_test.dart` | `859faf6b2136891ed6498a8e93910cac8fd0f7855a10ab46f3f42715f77fdd35` |
| `probes/dea485_real_review_probe_test.dart` | `b3fb3629c4e78d8cb1d52e00e1ad5cf6c1550c140b92f811392db8413dc0a922` |

## 修复内容

| ID | 根因 | 修复 |
| --- | --- | --- |
| Q1 | `SpaceProfileController.loadMore` 未重复选中月份；服务端游标绑定 month/offset，真实接收端 422 | 续页请求带上 `month: anchoredMonth`（offset 原本已带） |
| Q2 | `SpaceFollowStore.seedFromPosts` 会用“写完成之后”才返回的旧页面快照覆盖已确认关系 | 页面快照只补未知作者；关系只由 store 的写入/对账/`follow.changed` 变更 |
| Q3 | 删除/评论失效只清理活动流；`switchScope` 从 parked 快照恢复时不重新应用 tombstone/scrub | 删除与评论失效覆盖活动流、pending 页及两个 parked 快照；恢复时经 `_admitIncoming` 再应用 tombstone/reference/comment scrub |
| Q4 | 切换作用域触发首屏刷新会递增 generation，旧 loadMore 的 `finally` 不再释放 `loadingMore` | `switchScope`/`resetSession`/`_loadFeedFirst` 主动重置 `loadingMore`，切换时递增 generation 使旧请求失效 |
| Q6 | 卡片头像只种下部分身份且 controller 因 seed 存在而跳过完整 Profile 拉取 | controller 总是补全一次授权 Profile（seed 仅作首帧占位），签名与 Profile 入口一致；失败仍保留 seed 并在刷新时重试 |

另补：关注关系在“刷新进行中”变化时，刷新结束后从首屏重取关注流，避免在途首屏覆盖新关系。

## 并入常规回归（默认 `test/` 收集）

| 探针/边界 | 常规测试 |
| --- | --- |
| Q1 月份续页参数 | `test/space_profile_controller_test.dart`（month/cursor 断言）+ `test/space_profile_real_api_test.dart`（真实后端月份续页） |
| Q2 旧快照覆盖 | `test/space_feed_scope_test.dart`（store seed 规则） |
| Q3 删除复活（含引用/评论文本） | `test/space_feed_scope_test.dart`（parked tombstone + reference/comment scrub） |
| Q4 loadingMore 生命周期 | `test/space_feed_scope_test.dart`（跨模式分页） |
| Q6 完整身份 | `test/space_profile_entries_test.dart`（头像入口签名） |
| 刷新中关注变化 | `test/space_feed_scope_test.dart` |

## 修后全量实跑（候选 `7cfed39`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +826 / ~14 skipped；linux-integration +14
```

14 个 skip 仍是可选真实后端/截图环境未设置，不计为通过。格式化：本轮改动文件
`dart format --output=none --set-exit-if-changed` → 0。

## 未运行 / 保留

- Android / Windows / 真实折叠屏：NOT RUN。
- 远端 CI：未等待。
- Q5（DSH 工具面 24→28）由 Forge 处理，不在本目录。
- 未合并、未部署、未交 QA、不置 Done。
