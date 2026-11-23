# 手机个人资料页：海景封面与头像花边动效（DEA-492）

基线 `ae046172b51d33df371959129830bfbec2532ba3`。只改 `client/` 的手机资料页、消息页头像入口及其资源/测试，
未改服务端、契约、公开主页、Space、头像上传协议或消息业务类型。

## 页面结构

| 区域 | 实现 | 依据 |
| --- | --- | --- |
| 封面 | 共享海浪素材（见下），高度 = 视口高 × 0.25，限制在 168–260dp | issue 要求封面约占首屏四分之一；默认素材按用户要求从稿中裁出纯海浪，不含头像、标题、按钮 |
| 头像 | 104dp（窄于 360dp 时 92dp），顶部在封面下沿上方 45%、下方 55% | 头像跨在封面与浅色正文交界处 |
| 昵称 / 账号 | 纯色正文区、头像右侧，读取服务端真实 Profile | 不写死示意图昵称；长昵称换行 |
| 签名 | 单独成行、整行宽度，标签「签名」 | issue 明示 |
| 主操作 | 「编辑资料」（深青实心）与「个人主页」（浅青 tonal）两枚胶囊按钮 | 保留两个明显入口 |
| 其他入口 | 查看其他账号资料、设置、退出登录 + 退出说明 | 原数据与确认对话框全部保留 |

放大字体（≥ 1.35×）时昵称移到头像下方，两枚按钮改为整行堆叠，避免 200% 字号把按钮文字挤成两行或裁切。

## 默认海浪与本人封面

- 共享默认素材：`assets/profile/default-cover.png`，604×326，sha256
  `85e4f78178c812b90f453be0c9033ea49b4fd1223a84c91f70719d673edc6ba9`，422141 字节，未重编码。
  来源是 issue 附件 `profile-layout.png`（sha256 `3f029927…5965d`）的 `x=420 y=150 w=604 h=326`
  裁切，避开了返回箭头、标题和头像；生成脚本 `tool/crop_default_cover.py`。
  服务端打包同一文件并作为无自定义封面账号的 `GET /covers/{account}` 响应；客户端只在首帧/加载中
  显示同一 bundle 图，不另造默认图。
- 本人上传：资料页「编辑资料」→「封面」→ 复用图片选择对话框（路径 / 链接 / base64），
  `ProfileGateway.updateCoverFromPath/Url/Base64/Bytes` 走 `POST /me/cover`，随后重新读取
  展示图（不显示上传原图）。上传失败（413/415/503/网络）只提示错误，屏幕上的旧封面保持不变。
- 读取：每次打开资料页都 `GET /covers/{account}` 并以 ETag 重新验证；封面缓存与头像缓存分开，
  避免同账号两份字节互相覆盖。服务端返回 `X-BB-Cover-Default` 与 `cover_version`，
  客户端据此区分默认图与自选图。
- 本地上限：源文件 8 MiB（客户端在发请求前校验），展示响应 512 KiB。

## 守卫路由（独立 Dart 客户端 / DSH）

`POST /v2/profile/view_cover`：`{expected_identity, account?}`，返回
`{account, cover_url, cover_version, mime_type, data, is_default}`；`account` 缺省为本人，
可为已存在的他人账号。
`POST /v2/profile/update_cover`：`{expected_identity, base64}`，只写登录会话本人；
base64 必须是规范 padded standard 形式，解码后 ≤ 8 MiB；/me/cover 的 Bearer 由客户端注入。
本地请求体预算 12 MiB，多出的字段/账号目标一律 422。


## 形状与动效

| 项 | 值 | 说明 |
| --- | --- | --- |
| 花边形状 | 9 瓣正弦圆润波峰（`_ScallopPainter`），静态深度 0.085，转动时最深 0.135 | 对齐 MaterialShapes `Cookie9Sided` 的连续圆润波峰；不是锯齿、光环或进度弧 |
| 转动 | 一次 −0.42 圈 → 0，900ms，`easeOutCubic` | 波峰依次经过并自然减速停稳；结束后无 ticker，不无限循环 |
| 形状变化 | 转动期间波峰加深，停稳回到静态轮廓 | 借鉴 expressive shape motion 的连续转动与形状变化，不套加载语义 |
| 照片 | 圆形裁剪，永不带旋转 | 照片保持正向；花边只是照片后面的独立图层 |
| 进入 | 消息页页头头像 44dp 经 Hero 飞到封面边缘 104dp，360ms，页面同时 360ms 淡入 | Hero 只在 PageRoute 之间生效，因此手机端改为整屏路由（桌面/折叠屏仍用原对话框） |
| 返回 | 同一 Hero 反向飞回消息页页头入口，页面 300ms 淡出 | 返回位置与尺寸可断言 |
| 减少动画 | `MediaQuery.disableAnimations` 时不转、不加深，直接静态轮廓 | 尊重系统设置；Hero 与路由仍由框架统一处理 |
| 快速进出 | 动画不持有输入；关闭按钮在首帧即可点 | 录屏与测试覆盖 40ms 内进入并退出 |

## 资料状态与入口

| 状态 / 入口 | 行为 |
| --- | --- |
| 默认头像 | 服务端 identicon 字节照常渲染，头像可点更换 |
| 自选头像 | 渲染服务端 re-encode 后的 PNG；更换后重新拉取 |
| 无签名 | 显示「还没有签名」斜体空态 |
| 加载 / 失败 | 顶部进度点 + 内联错误文案（`profile-error`） |
| 编辑资料 | 底部面板：更换头像、移除头像、修改昵称、修改签名；动作复用原有对话框与保存路径 |
| 个人主页 | 关闭资料页后由宿主打开既有公开主页（本单未改） |
| 其他账号 / 设置 / 退出登录 | 原有对话框与返回结果不变 |

## 验证入口

```bash
# 单元/Widget（手机页布局、长文本、放大字体、动效、Hero、入口）
flutter test test/profile_phone_layout_test.dart

# 同尺寸（390×844）截图，需 CJK 与图标字体
QA_SCREENSHOT_DIR=.qa-artifacts/screenshots/dea492 \
QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
QA_ICON_FONT=$FLUTTER_ROOT/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
QA_AVATAR_PNG=test/fixtures/avatars/sample-photo.png \
QA_COVER_PNG=test/fixtures/covers/custom-cover.png \
flutter test --update-goldens test/profile_phone_screenshot_test.dart
```

截图内的头像是 `tool/generate_profile_fixture.py` 生成的合成测试图（顶部有一个朝上的橙色标记，便于看出照片没有随花边旋转），
不是产品素材。截图是 390×844 视口下的 widget-test 渲染；真实进程录屏与 Android 实机结论见本单 issue 回填。
