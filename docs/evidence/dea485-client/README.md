# DEA-485 客户端阶段证据（Muse）

基线 `246c690bd4cca4832b3d53c5757eb804e92f3531`，分支 `agent/muse/bac7692aa6f7`。
本阶段只改 `client/` 与本目录；未改 `server/`、`server/contract/`、公共 `scripts/`/CI。

## 本阶段交付（不依赖 Forge 新接口的部分）

- 主页**模块容器**：`SpaceProfileModuleRegistry`（应用内静态注册，非插件下载）、
  `SpaceProfileModule`/`SpaceProfileModuleScope`、`SpaceProfilePage` 负责身份、布局与模块排列；
  说说模块 `spacePostsModule()` 注册后负责列表、分页与滚动，新增模块不改说说查询。
- **双入口**：Profile 面板「个人主页」按钮、空间说说卡片发布者头像，两处都调用同一个
  `openSpaceProfile(...)` → 同一个 `SpaceProfilePage`；返回保留来源位置（push 覆盖，不重建）。
- **响应式布局**：窄屏日期按钮 + 竖向年月抽屉（选完收起）；宽屏列表旁目录；平展折叠屏把目录放进
  第二窗格（`SpaceLayout` 的 `verticalHingeX`/`panes()`），宽屏内容限制在 1200 逻辑像素内。
- **年月目录**：只渲染服务端返回的非空月份，年月倒序；「回到最新」；选中月份与「跟随滚动」两种标记。
- **关注按钮**：未关注/已关注两态；点已关注先弹确认框并显示目标昵称；失败保留真实关系并提示；
  自己的主页不显示、也不发写请求。
- **会话状态边界**：`SpaceProfileController` 单一持有身份、目录、选中月份、可见月份、分页游标与
  关注关系；请求带 generation 围栏，旧月份的迟到响应不能回填当前列表；游标分页去重。
- **复用**：`SpacePostCard`、图片加载器 `SpaceImageLoader`（共享内存/磁盘缓存）、
  `SpaceAvatarStore`（授权头像 + ETag）、`SpaceStateView`、`spaceRelativeTime` 与设计 tokens；
  未复制媒体查看器、评论或转发实现。

## 服务端契约状态（为什么不接月份/关注）

`SpaceProfileAdapter`（生产适配器）当前只使用**现有共享契约**的 author-scoped
`list_posts` 提供身份与时间线：

- 时间线：`listPosts(author: userId, cursor, limit)`，游标已在服务端按 author 绑定；
- 月份目录与关注关系：`supportsMonths = false`、`supportsFollow = false`，页面隐藏这两个控件，
  不猜端点、不在客户端下载全部历史后搜索；
- 契约落地后只需替换 `SpaceProfileAdapter` 的四方法并打开两个开关，UI/状态机不变。

## 实跑命令与结果（2026-11-17，本机 Linux x64）

```bash
# 客户端全量验收入口（analyze + widget/unit + Linux integration）
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 \
  xvfb-run -a --server-args="-screen 0 1280x1024x24" \
  bash scripts/run_flutter_tests.sh client
# RESULT=PASS
#   flutter analyze: PASS
#   flutter test:    PASS  (+804 passed, ~13 skipped)
#   linux-integration: PASS (+14 passed, 真实 Linux 进程 + 真实 HTTP 服务)
```

本次新增测试（含在上面的 `flutter test` 内，均可单独运行）：

| 文件 | 覆盖 |
| --- | --- |
| `test/space_profile_module_test.dart` | 注册表去重/排序；注册最小测试模块后容器与说说模块同屏；空容器状态 |
| `test/space_profile_page_test.dart` | 身份与复用卡片；转发按转发时间显示与归档；窄屏抽屉跳月并收起；回到最新；宽屏目录；折叠屏第二窗格；无月份/关注能力时不出现死控件；滚动跟随月份；首屏失败重试；空月份空态 |
| `test/space_profile_follow_test.dart` | 关注写入权威结果；取消确认/取消不改关系；失败不伪装成功；自己的主页无关注 |
| `test/space_profile_controller_test.dart` | 乱序响应的 generation 围栏；选中/可见月份分离；游标去重；身份回退；无目录能力不请求月份 |
| `test/space_profile_entries_test.dart` | 空间卡片头像进入同一主页并返回；Profile 面板入口返回同一账号 |

新增测试单独执行：`flutter test test/space_profile_module_test.dart test/space_profile_page_test.dart
test/space_profile_follow_test.dart test/space_profile_controller_test.dart
test/space_profile_entries_test.dart` → 30 passed。

格式化：本次改动文件 `dart format --output=none --set-exit-if-changed` → 0。
仓库全量 `dart format .` 在当前 SDK 下仍会改动 63 个本次未触碰的既有文件，属既有格式漂移，
本阶段未顺手重排。

## 截图（测试替身，不是真实后端）

由 `test/space_profile_screenshot_test.dart` 渲染真实 widget 树生成，数据来自
`FakeSpaceProfileGateway`（**合成账号 10000002 / 测试数据，非真实后端、非真实用户**）。
设备：Linux x64 + Xvfb 软件光栅；逻辑视口见文件名。

```bash
QA_SPACE_PROFILE_SCREENSHOT_DIR="<repo>/docs/evidence/dea485-client/screenshots" \
QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-DemiLight.ttc \
QA_ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
  flutter test test/space_profile_screenshot_test.dart --update-goldens
```

| 文件 | 视口 | 说明 |
| --- | --- | --- |
| `screenshots/space-profile-phone.png` | 390×844 | 窄屏：日期按钮、日报式卡片、已关注态 |
| `screenshots/space-profile-phone-directory.png` | 390×844 | 竖向年月抽屉（仅非空月份，缺 2026-08） |
| `screenshots/space-profile-phone-october.png` | 390×844 | 选 2026-10 后从 10-30 开始，日期按钮同步 |
| `screenshots/space-profile-wide.png` | 1440×900 | 宽屏：列表 + 侧边目录，内容居中限宽 |
| `screenshots/space-profile-fold.png` | 1024×768，x=512 竖折 | 目录进入第二窗格，不拉宽手机版 |

## 未完成 / 未运行（明确分列）

- **未接真实后端**：主页时间线适配器已实现并走现有 author-scoped `list_posts`，但本阶段没有
  跑真实后端 + 双账号的端到端主页；截图与页面测试均使用测试替身。
- **月份定位、关注读写、关注者信息流开关**：等待 Forge 的共享契约；页面已有可启用的 UI 与状态机，
  但生产适配器主动报告不支持。
- **卡片互动（详情/赞/评论/转发/媒体查看）**：主页里复用卡片目前只读；详情栈是 SpacePage 自身状态，
  需要在集成阶段接一个能返回主页的详情路由，本阶段未猜接口、未复制详情实现。
- **Android / Windows 真机、真实折叠屏**：NOT RUN。折叠布局仅模拟 `DisplayFeature`。
- **CI**：本次未推送前未跑远端 CI；本地命令如上。公共 CI 未改动。
