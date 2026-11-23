# DEA-494 会话列表视觉与共享左栏

状态：实现交接，不是独立 QA。基线 `96cd0252fb66f2323daf1097630ebbabc3c4a6b8`（BB main），
改动只在 `client/`。

## 1. 范围

只改既有共享会话列表 `UsersListView` / `_UserRow`：手机列表页、桌面与展开折叠屏双栏
左栏使用同一实现，不新增平台专版，不改服务端、契约、排序、在线筛选、未读来源和聊天页。
双栏外壳本身归 DEA-493；本单只保证列表可以按账号标记当前会话，并在窄左栏约束下正常呈现。

## 2. 视觉与状态

- 底：沿用 `AppColors.paper` 暖白与既有 `AppSpacing` / `AppRadius` / 文字 tokens，没有第二套主题。
- 当前会话：只有该行的昵称、时间和最后消息包在 `AppColors.accentSoft` 浅青笺内；笺的左缘
  有一段短弧指向头像。头像留在笺外，不铺底也不进入笺。
- 其他行：不铺底。
- 头像：圆头像；在线时才在右下角显示绿色点（离线不显示灰点，在线筛选仍按同一
  `PresenceDirectory` 最后确认值）。头像被在线点、未读和选中笺各自独立影响，不互相复用。
- 未读：右侧时间下方、预览行末尾的深青圆点数字（1–99、99+），来源仍是服务端未读推导，
  不因筛选或选中清空。
- 选中态按 `account` 保存，不按行号；刷新、重排、筛选后仍跟随同一联系人。
- 窄宽度（<520）收紧左右留白、头像 46px、笺内边距与字号；行内容仍单行省略，不出现
  `RenderFlex` 溢出。列表内容仍限制在 760 宽内居中，双栏左栏直接用可用宽度。
- 加载、失败、在线筛选空态、目录空态、长文本、“尚无消息/尚未联系”保持既有行为。

## 3. 与 DEA-493 双栏外壳的接口

`UsersListView` 新增可选参数 `selectedAccount`。双栏外壳把右侧正在显示的会话 account 传入
即可高亮左栏对应行；不要复制列表、改行号或另写折叠屏/桌面版本。

手机独立列表页由 `HomeView` 记录最近打开的会话并传入；从聊天页返回后列表仍标出该会话。
该值是展示状态，不写消息、不写已读、不影响排序或未读计数。

## 4. 可访问性与测试钩子

- 行 `Semantics(selected:)` 标出当前会话；头像语义为“在线/离线”；未读仍有“N 条未读”语义。
- `UsersListView.noteKey(account)`：当前会话笺，仅选中行存在。
- `UsersListView.avatarKey(account)` / `presenceDotKey(account)`：验证头像在笺外、在线点独立。
- `rowKey`、`unreadKey`、`onlineOnlyKey`、空态/错误键保持原值，既有测试继续可用。

## 5. 验证（本候选实际执行）

环境：Arch Linux；Flutter 3.47.9 / Dart 3.13.7；Linux 桌面 Xvfb；
Android/Windows 未运行。

| 检查 | 结果 |
| --- | --- |
| `QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client` | `RESULT=PASS`，exit 0；analyze PASS、flutter-test 967 passed/18 skipped、linux-integration 14 passed |
| 新增 `test/chat_conversation_note_test.dart` | 6 passed：仅当前会话有笺、笺在头像外、在线点/未读/选中独立、重排后按账号跟随、手机返回保留、380/320 窄左栏无溢出、筛选隐藏/恢复不丢选中 |
| `test/chat_list_screenshot_test.dart`（opt-in，`--update-goldens`） | 4 张 390×844 / 400×844 / 1440×900 PNG：手机列表、手机返回选中、400 宽左栏、与现有 `ChatPage` 并排的评审组合 |
| Linux 集成 `auth_flow_test.dart` 增加 DEA-494 断言 | 真实 Linux embedder 中从聊天返回手机列表后笺存在，且 `note.left > avatar.right` |

截图是 golden/widget-test 渲染（FontLoader + 合成数据），不是 Android/Windows 运行时截图。
1440×900 的双栏组合只是截图测试里的评审 harness，生产双栏外壳仍由 DEA-493 接入。

## 6. 涉及文件

- `client/lib/ui/chat/users_view.dart`：列表视觉、选中笺、在线点、未读位置、窄左栏布局。
- `client/lib/ui/home_view.dart`：把最近打开的会话 account 传给共享列表。
- `client/test/chat_conversation_note_test.dart`：新增定向回归。
- `client/test/chat_list_screenshot_test.dart`：新增 opt-in 视觉证据。
- `client/test/chat_flow_widget_test.dart`、`client/test/chat_presence_refresh_test.dart`：
  在线状态断言从行内文字改为头像在线点。
- `client/integration_test/auth_flow_test.dart`：真实 Linux 进程内返回列表后的笺断言。
