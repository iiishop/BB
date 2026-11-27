Profile 三形态与折叠屏调查（DEA-496，第 2 版规格）
==================================================

实现基线：`609811ffdc090bd71b734dd8a1bdf674036cd870`。
本轮只复用批准的 Profile 内容及修复已复现的坐标偏移，不改消息事实、服务端或契约。

## Profile 与调用方

`HomeView._openProfile` → `openProfilePanel` → `_ResponsiveProfileFrame`
仍按实时 `MediaQuery` 选择手机整页、展开屏左面板及右侧模糊、桌面居中卡片。
三个容器现在都使用 `ProfilePanel._buildContent`，不再保留旧的 `_buildPanel` 内容树。
封面高度、头像大小和窄屏排列按 **面板实际约束** 计算；桌面 440×700 上限及展开屏切分宽度保留。
关闭图标/提示在桌面为「关闭」，其他形态为「返回」。手机 Hero 路由不变。

所有形态的头像、移除、昵称、签名和封面操作均从「编辑资料」进入同一个 sheet，
复用原 gateway、重新读取及失败处理。个人主页、其他账号、设置和登出的结果仍交回宿主处理。

QA 菜单返工基线 `fa47da17e508773e30dd7f03ac08343c3e19809f`：原外壳切换会卸载内容 State，
导致已经打开的菜单或编辑框返回时丢弃操作。一次 `openProfilePanel` 现在持有一个内容 GlobalKey，
让同一内容 State 随手机/展开屏/桌面外壳迁移；保留在途操作和已加载资料，不因重排重新读头像/封面。
编辑菜单和文本编辑框都允许滚动；1024×480、200% 字号下可滚到签名并保存。
现有 Profile 回归覆盖菜单打开期间六种形态互转、编辑框已打开时重排，以及三形态矮窗口的实际保存。

## B：已复现的按钮偏移，与尚未定位的真机未双栏

可重复输入：390×844 手机登录首页后，切到 800×840，DPR=1；
`fold / postureFlat / Rect.fromLTWH(400, 0, 0, 840)`；
`padding=(left:24, top:20, right:12, bottom:16)`；启用真实首页的 Chat/Space 外壳。
数据为合成账号，登录路径由测试替身提供（Linux 集成中的登录与 Profile 为真实 HTTP 桩）。

| 链路 | 修前 | 修后 |
| --- | --- | --- |
| 首页 constraints / MediaQuery | 800×840 / 800×840 | 相同 |
| 外壳 | compact=false，rail=92，foldCapable=true | 相同 |
| 扣 rail 的页面宽度 / fold.x | 708 / 308 | 相同 |
| Chat 分支 | deviceWidth=800 ≥ 720，split=true | 相同 |
| SafeArea 后 workspace 实际宽度 / 屏幕原点 x | 672 / 116 | 相同 |
| workspace 收到的 fold.x | 308（仍为 SafeArea 外坐标） | 284 |
| 双栏聊天左边界 / grip 中心的屏幕 x | **424** | **400** |
| 全屏聊天左边界 | 24（保留安全区） | 24 |

修复点是 `_splitChatScaffold` 的 SafeArea 原点转换；rail 与 SafeArea 使用相同的
`translateDisplayFeatures`，不改变 `usesSplit` / `canExpand` 的宽度与姿态策略。
`chat_workspace_widget_test.dart` 保留登录→展开→打开 Profile→双栏/全屏往返断言。
修前用相同回归配基线 `HomeView` 得到 local x=308（期望 284）；直接首页反例得到 screen x=424（期望 400）。

用户设备“没有双栏”的原因仍 **尚未定位**。没有设备输入，不据此宣称用户问题已全部修好。
例如以下是保留的明确策略，而非把 Profile 和 Chat 强行统一：

| 首页输入（含 92px rail 时按设备宽度传递） | Chat | Profile |
| --- | --- | --- |
| 719 / 竖向 flat fold | 单栏，无切换钮 | folded |
| 720、800 / 竖向 flat fold | 双栏，有切换钮 | folded |
| 800 / 竖向 half-open hinge | 双栏，有切换钮（沿用现有策略） | desktop |
| 800 / 横向 flat fold | 单栏，无切换钮 | folded（既有半宽回退） |
| 800 / cutout 或无折叠特征 | 单栏，无切换钮 | desktop |
| 无特征：991 / 992 设备宽度 | rail 后 899 单栏 / 900 双栏，无切换钮 | desktop |

真机最小采集（仅布局数据，无账号、token 或消息正文）：

1. 客户端版本/完整 SHA、设备型号/系统版本、窗口是否分屏；从手机展开的操作顺序和当前路由。
2. 同一次展开时根 `MediaQuery.size/devicePixelRatio/padding/viewInsets`，以及每个
   displayFeature 的 `type/state/bounds`（逻辑像素）。
3. 在 `HomeView._appScaffold`、`_chatScaffold`、`ChatWorkspace` 的 LayoutBuilder
   断点读取 constraints、rail、displayWidth、转换后的 feature；记录 `usesSplit`、`canExpand`。
4. 同一输入下的消息页/Profile 截图及按钮是否出现、是否能点。
   调试构建可用 Flutter DevTools 在上述入口暂停读取，无需上传会话文件或聊天数据。

## C：共享来源与保留差异（供既有客户端地图更新）

唯一共享来源 `lib/ui/display_features.dart` 只提供 fold/hinge 类型、竖向、flat 姿态事实与坐标平移。

| 调用方 | 共享项 | 页面自己的规则 |
| --- | --- | --- |
| Profile mode / foldedPanelWidth | flat fold，竖向 | flat 优先于 600；横向回退半宽；左面板最小 280 |
| ChatWorkspace.splitFeatureOf | fold/hinge，竖向 | 不限制为 flat；fold 720（设备宽度），无特征 900（可用宽度） |
| HomeView rail 与 Chat SafeArea | 保留 type/state 的 bounds 平移 | 导航断点 720、rail=92、安全区及动画进度归宿主 |
| SpaceLayout / SpaceProfilePage | 继续使用 SpaceLayout | 解析所有 displayFeature（包括 cutout）并选择可用区域，横向遮挡/宽特征规则与 Chat/Profile 不同；本轮不合并、不改行为 |

`SpaceBreakpoints.compact` 与首页 720、Space masterDetail 与 Chat 900、Profile 600
分别表达不同的导航/内容策略，不因数值相同合并。Space 宽特征分类可另行审查，不能借本轮改语义。
DEA-495 / PR #95 的 `docs/client-map.md` 由 Orion 接续；此处仅提供本批变更清单，TaskScheduler 不变。

## 可重复检查

```bash
flutter test test/profile_panel_widget_test.dart test/profile_phone_layout_test.dart \
  test/profile_transition_reflow_test.dart test/profile_cover_widget_test.dart \
  test/chat_workspace_widget_test.dart
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client
```

渲染沿用 `test/profile_screenshot_test.dart`：390×844、1024×768（x=512 零宽 flat hinge）、
1440×900，DPR=1，合成资料、真实 CJK/MaterialIcons 字体。截图用 `--update-goldens` 输出到
被忽略的 `.qa-artifacts/screenshots`，不更新仓库金图；采集前等图片解码，避免默认封面首帧空白。
渲染只证明上述模拟输入；Linux 集成是独立进程，Android/Windows 和用户真机需单独验证。
