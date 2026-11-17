# DEA-485 客户端证据（Muse，第二轮：契约接入完成）

- 客户端分支：`agent/muse/bac7692aa6f7`
- 基线：`246c690bd4cca4832b3d53c5757eb804e92f3531`
- 本目录包含五轮：契约接入（`b6becc4`）、独立 QA 返工 Q1–Q4/Q6（`7cfed39`，
  细节见 `q1-q6/README.md`）、QA round 2 返工 R2-A/R2-B/R2-C（`55a8683`，
  细节见 `r2/README.md`）、QA round 3 返工 R3 关系失效缓存（`0130053`，
  细节见 `r3/README.md`）与 QA round 4 返工 R4 对账后关系失效（`50e6b51`，
  细节见 `r4/README.md`）
- 合并的固定依赖：Forge PR #73 / `5e354ab9d5ef4469e6e69c4c931d61a0cd465268`
  （契约入口 `docs/contracts/dea485-profile-follow.md`；合并提交见 branch head）
- 写入范围：`client/`、`docs/evidence/dea485-client/`、`client/tool/generate_space.py`（生成器）
- 未改：`server/`、`server/contract/`、公共 `scripts/`/CI

## 本轮完成

- **契约接入**：由 `server/contract/space-v1.json` 重新生成 Dart DTO/方法/校验
  （`client/tool/generate_space.py` 把生成类型 `ProfileMonth` 命名为 `SpaceMonthCoordinate`，
  避免与 UI 的 `SpaceProfileMonth` 值对象冲突）。
  - `list_profile_posts` / `list_profile_months` / `get_follow` / `set_follow` / `list_posts.scope`
  - `SpaceProfileAdapter` 直接用上述动作，游标保持服务端不透明游标语义，不跨查询复用。
- **只看已关注**：`SpaceController` 增加 `all|following` 两种作用域，各自保留页面、游标与
  待确认新说说；`SpacePage` 保存两种视图各自的滚动偏移。空结果给专门空态，绝不回退全部。
  离开空间主区再进入（`SpacePage.active` 由 HomeView 传入）会重置为 `all` 并清空两份缓存；
  换账号（新 scopeKey/page key + 新 store）同样从 `all` 开始。
- **关注单一所有者**：`SpaceFollowStore`（每账号一个）持有关系、按目标串行写入、失败用
  `get_follow` 对账、关系变化递增 revision。空间卡片与主页头共用该 store，跨卡片、跨页面即时同步。
  `follow.changed`（无 ID 的私有失效）清空缓存并重取已知作者，同时使旧关注流游标失效。
- **旧关注游标 422**：关注流 `loadMore` 收到 422 `validation_error` 时丢弃旧游标，从首屏重取，
  并以“关注关系已变化，已从首屏刷新”提示；不混用另一模式的结果。
- **固定浏览时差**：主页打开时捕获一次 `timezone_offset_minutes`（-840…840），目录、时间线与
  卡片日期都用同一个偏移渲染；不再用会变化的 `toLocal()`。卡片月份归属与显示日期一致。
- **主页卡片互动 + 可返回主页的详情**：主页现在复用现有 `SpaceDetailView`/`SpaceDetailController`
  打开独立详情路由（同一 body/图片/引用/评论/浏览与点赞语义），关闭后把最终 post 写回卡片，
  不重载时间线、不丢浏览位置；同时打通点赞（乐观+失败回滚）、删除（刷新目录）、转发（现有创作页）、
  图片查看（现有 viewer/缓存）。
- **复用与边界**：`SpacePostCard`（新增可选 `timelineAt`/`timezoneOffsetMinutes`/`following`）、
  `SpaceImageLoader`、`SpaceAvatarStore`、`SpaceStateView`、`SpaceComposePage`、设计 tokens。

## 实跑（本机 Linux x64）

### 客户端验收入口（候选工作树）

```bash
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   flutter analyze: PASS
#   flutter test:    PASS  +843 / ~14 skipped（R4 返工后；R3 轮为 837，R2 轮为 833，Q1–Q6 轮为 826，契约接入轮为 818）
#   linux-integration: PASS +14（真实 Linux 进程 + 真实 HTTP 服务）
```

新增/更新测试覆盖（均含在 `flutter test` 内）：

| 文件 | 覆盖 |
| --- | --- |
| `test/space_profile_controller_test.dart` | 乱序月份响应围栏、选中/可见月份、游标去重、固定时差跨月边界 |
| `test/space_profile_page_test.dart` | 身份/复用卡片、转发时间、抽屉跳月与收起、回到最新、宽屏/折叠窗格、滚动跟随、首屏失败重试、空月份 |
| `test/space_profile_follow_test.dart` | 关注权威结果、取消确认、失败回滚/对账、自己的主页无关注、`follow.changed` 刷新 |
| `test/space_profile_actions_test.dart` | 卡片点赞/失败回滚、删除并刷新目录、打开既有详情路由并返回、时差统一日期 |
| `test/space_feed_scope_test.dart` | 关注作用域空态、双模式各自滚动位置、离开主区重置、旧游标 422 刷新、关注写入失效刷新、账号切换重置、`follow.changed` 事件 |
| `test/space_follow_sync_test.dart` | 同一作者多卡片 + 主页头的关注状态同步；自己的卡片无关注 |
| `test/space_profile_module_test.dart` | 模块注册表去重/排序、测试模块与说说模块同屏、空容器 |
| `test/space_profile_entries_test.dart` | 空间卡片头像进入同一主页并返回；Profile 面板入口 |
| `test/space_profile_real_api_test.dart` | 真实隔离后端双账号：作者时间线/目录、关注读写、关注流、旧游标 422 |

### 真实隔离后端（双账号）

本 run 在本机启动隔离服务端（临时 DB/媒体目录，仅合成账号），然后：

```bash
BB_SPACE_API_BASE=http://127.0.0.1:8766 \
  flutter test test/space_profile_real_api_test.dart
# 1 passed, exit 0
```

原始输出：`real-backend/profile-real.log`。服务端仅作为依赖使用，未修改；测试后已停止该进程，
临时数据库/媒体在 `client/.qa-artifacts/dea485-real/`（已忽略，不提交）。

格式化：本轮改动文件 `dart format --output=none --set-exit-if-changed` → 0。

## 截图（测试替身）

`test/space_profile_screenshot_test.dart` 生成，数据来自 `FakeSpaceProfileGateway` + 合成账号
（**测试替身，不是真实后端、不是真机**）。固定偏移 480 分钟用于演示目录与卡片日期同源。

| 文件 | 视口 | 说明 |
| --- | --- | --- |
| `screenshots/space-profile-phone.png` | 390×844 | 窄屏：日期按钮、已关注、复用卡片 |
| `screenshots/space-profile-phone-directory.png` | 390×844 | 竖向年月抽屉（无 2026-08） |
| `screenshots/space-profile-phone-october.png` | 390×844 | 选 2026-10 从 10-30 开始并继续读更早 |
| `screenshots/space-profile-wide.png` | 1440×900 | 列表 + 侧边目录 |
| `screenshots/space-profile-fold.png` | 1024×768，x=512 竖折 | 目录进第二窗格 |

## 未运行 / 已知限制

- Android / Windows / 真实折叠屏：NOT RUN（本轮只在 Linux + 模拟 DisplayFeature 上验证）。
- 远端 CI：未等待；本地验收入口已 PASS。未合并、未部署、未置 Done。
- 真实后端仅覆盖本轮 profile/follow/scope 动作；媒体查看、评论、转发在真实后端的完整回归
  仍由既有 Space 真实接口测试与 Sentinel 独立 QA 承担。
- “全部/只看已关注”滚动位置是页面级内存状态；应用重启后按规格回到默认（关闭）状态。
