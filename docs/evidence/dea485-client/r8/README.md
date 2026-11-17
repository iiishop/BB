# DEA-485 QA round 8 返工证据（R8 待返回操作反馈生命周期，Muse）

- 修前固定候选：`74e12b1b92c997369b6601d8619353c858734b17`（唯一集成分支 `agent/orion/82aaa227aaf8`，PR #75）
- 修后候选：`d3decd6`（本目录所在提交的修复提交；分支 `agent/muse/bac7692aa6f7`）
- 探针：Sentinel round-8 附件原样保存于 `probes/`：
  - `dea485_round8_refresh_feedback_probe_test.dart` — SHA-256 `817410f7849e180d371296dc00e26fd590c97c571b4bf17f186ce48850fae3fe`
  - `dea485_round8_refresh_feedback_ui_probe_test.dart` — SHA-256 `23069e14d3d46a7c93adea29d7de0a1a4ac5fc7b0a9b35754764a1f962297621`
  - `dea485_round8_feedback_guard_probe_test.dart` — SHA-256 `dd38fab8cde2380da65b0517ce9b0f10f81f213ca1eb94d05fbda0cef1313189`
- 范围：只改 `client/` 与本证据目录；真实探针使用本机隔离 FastAPI（临时 DB/媒体、合成账号、端口 8773，采集后已停止）。

## 修前失败（74e12b1，真实接收端 + 双作者卡片）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8773 flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_round8_refresh_feedback_probe_test.dart      # 2 tests：1 pass / 1 failure
flutter test --no-pub --reporter=json \
  .qa-artifacts/dea485_round8_feedback_guard_probe_test.dart \
  .qa-artifacts/dea485_round8_refresh_feedback_ui_probe_test.dart   # 3 tests：2 pass / 1 widget TestFailure
```

失败点：
- `refresh_feedback replay=true`：A 的取关失败反馈在后台事件强制重读（`ensureLoaded(A, force)`）成功后
  被清空；A 对账释放、返回 false、busy 释放，但 `error=null`。
- `refresh_feedback_ui replay=true`：同样的后台刷新后，卡片不再显示失败提示。
- `feedback_guard` 与无后台刷新对照（replay=false）通过，说明并非所有路径失败。

原始 JSONL：`before/refresh-native.jsonl`、`before/refresh-ui-native.jsonl`。故障只注入 gateway 边界；
真实注册账号、真实事件重放与生产 store。UI 红色为原始 TestFailure 被 reporter 包装为 error。

## 修后通过（同一探针、同一接收端）

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8773 flutter test ...（真实探针） # 2/2 success，exit 0
flutter test ...（guard + UI）                                      # 3/3 success，exit 0
```

原始 JSONL：`after/refresh-native.jsonl`、`after/refresh-ui-native.jsonl`。同轮复跑此前全部客户端
反例（R7 8、R6 3、R5 3、R4 3、Q2/Q3/Q4/Q6 4、R2 3、R3 2）：**26/26 success，exit 0**
（`after/prior-probes-native.jsonl`）；既有真实 Profile/月份 API 测试 **1/1 success**
（`after/real-api-native.jsonl`）。

## 修复（待返回操作的反馈生命周期）

| 项 | 内容 |
| --- | --- |
| **root_cause_id** | `ensureLoaded` 成功无条件清除目标错误：后台事件强制重读会在写入尚未交还调用方前清掉待展示反馈（R7 目标归属 → R8 反馈生命周期） |
| **不变量** | 待返回操作的失败反馈必须保留到调用方可见；操作结束后的正常刷新仍可清除旧错；跨目标反馈保持隔离；成功操作不展示其他目标的错误 |
| **状态所有者 / 全部入口** | `SpaceFollowStore.ensureLoaded`（读取开始/完成时的在途写入判断）、`_errors`/`_clearError`、`setFollowing` 开始/写入 catch/对账/结算、`handleFollowChanged` 强制读；`toggleSpaceFollow` 的 `!applied` + 目标错误读取 |
| **共同修复点** | 读取开始时记录该目标是否有在途写入；读取完成时若开始或完成时仍有在途写入，则不清除该目标错误。写入结束后的普通刷新按原语义清除旧错 |
| **contract_gap** | none |
| **owner** | Muse（客户端）；Orion 唯一集成 |

## 并入默认回归（`test/` 常规收集）

`client/test/space_r8_feedback_lifecycle_test.dart`（3 tests）：

- 单元：A 未发送失败并等待对账时，后台事件强制重读成功不清除 A 的错误；写入返回后错误仍在；
  操作结束后普通刷新可清除旧错。
- 组件：双作者卡片；后台刷新后 A 的失败提示仍在（replay 场景）。
- 组件：A 保留错误后，成功关注 B 不展示 A 的错误（`!applied` 守卫 + 目标级读取）。

R7/R6/R5/R4/R3/R2/Q 系列常规回归全部保持通过。

## 修后全量实跑（候选 `d3decd6`，本机 Linux x64）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   analyze PASS；flutter test +856 / ~14 skipped；linux-integration +14
```

14 个 skip 仍为可选真实后端/截图环境未设置，不计通过。格式化：本轮改动文件 0 差异。

## 未运行 / 保留

- 其他多错误/回退文案组合、Android/Windows/真实折叠屏、物理多设备、实际丢包/断网、
  DSH 安装/模型链路：NOT RUN。
- 未变组件（server 19 项、插件 122+lint、真实 Profile/月份边界）按无变化组件复用，由 Sentinel 判定。
- 远端 CI：未等待。
- 未合并、未部署、未交 QA、不置 Done；由 Orion 集成唯一新候选后再走 automated_qa。
