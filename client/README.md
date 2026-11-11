# bb_client — BB Flutter client

Flutter 客户端，一套代码出 Linux/Windows 桌面与 Android APK（`linux/`、`windows/`、
`android/` runner 均已就位）。本轮（STEP-1）交付 **注册 + 登录 + 会话持久化**：两个
响应式页面、一个可独立于 UI 运行的逻辑客户端入口，供 DSH MCP 插件调用。

```text
client/
  lib/main.dart            Flutter 入口（BB_API_BASE_URL / 会话文件定位）
  lib/app.dart             设计 tokens、ThemeData、根 Widget
  lib/ui/                  恢复中 / 登录 / 注册 / 注册成功 / 已登录 + 响应式外壳
  lib/services/            认证 service、HTTP 客户端、会话与磁盘存储、本地控制接口
  lib/models/              DTO 与 {error:{code,message,fields}} 错误模型
  lib/validation/          与服务端一致的即时校验（仅提示，服务端是唯一判定方）
  lib/config/              API base URL、会话文件路径解析
  bin/bb_client_api.dart   独立 Dart 逻辑入口（本地控制接口）
  test/                    widget/单元/真实 HTTP 桩测试
  integration_test/        Linux 桌面端到端 + 重启恢复用例
```

## 运行

```bash
flutter pub get
flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000
```

- 窄屏（< 960 逻辑像素）：单列，品牌头 + 全宽表单卡片，可滚动、SafeArea；
- 宽屏（>= 960）：左侧深青品牌面板 + 右侧 440px 表单列，窗口居中。

Linux 默认窗口 1180×780（`linux/runner/my_application.cc`），Windows 默认窗口同样是
1180×780（`windows/runner/main.cpp`）。Windows 构建/运行与 Android 运行在本环境
均为 **NOT RUN**：Windows 没有 MSVC 工具链、Android 没有模拟器/真机；Linux 截图不代表
这两个平台。

## 会话持久化

登录成功后，客户端把 `{account, username, token}` 写入会话文件（**不含密码**），
重启时先读取该文件并调用 `GET /auth/session` 验证，验证通过才进入已登录页面：

| 服务端结果 | 行为 |
|---|---|
| `200 {account, username}` | 进入已登录页，账号信息以服务端返回为准 |
| `401 unauthenticated` | 清除本地凭据，回登录页并提示「登录已失效，请重新登录」 |
| 502/504（不可达/超时） | **保留**本地凭据，回登录页提示「暂时无法验证登录状态」并给「重试验证」，绝不显示为已登录 |
| 本地存储读写失败 | 统一返回 `500 {"error":{"code":"session_storage_unavailable","message":"会话存储不可用","fields":[]}}`：登录不报成功、恢复不进入已登录、退出失败保持已登录并提示，本地接口同样不返回成功 |

会话文件位置（`BB_SESSION_FILE` 可覆盖，`--dart-define` 或环境变量均可）：

- Linux：`$XDG_DATA_HOME/bb/session.json` 或 `~/.local/share/bb/session.json`
- macOS：`~/Library/Application Support/BB/session.json`
- Windows：`%APPDATA%\BB\session.json`
- Android/iOS：应用私有 support 目录（`path_provider`）+ `session.json`

写入使用**每次独立的临时文件**再替换目标（POSIX 原子 rename；Windows 走备份-替换-回滚），
替换失败时旧凭据仍保留；文件以 `0600`、父目录 `0700` 写入（POSIX），Windows 依赖用户
配置文件 ACL。损坏/不完整文件会被忽略并删除，不会导致启动失败。

## 本地控制接口（给 dsh-plugin）

独立于 Flutter 视图运行，与页面共用同一个 `AuthService`、DTO、错误处理、会话与磁盘存储：

```bash
dart run bb_client_api \
  --server-url http://127.0.0.1:8000 \
  --host 127.0.0.1 --port 8787 \
  --session-file ~/.local/share/bb/session.json
# 等价环境变量：BB_API_BASE_URL / BB_CLIENT_HOST / BB_LOCAL_API_PORT / BB_SESSION_FILE
```

- 启动时读取共享会话文件并调用 `GET /auth/session`，只输出「已恢复本地会话 / 本地无有效会话 /
  已失效已清除 / 暂时无法验证（已保留）」，不打印账号、token 或请求体。
- 只允许监听 `127.0.0.1`，非回环地址直接以退出码 64 拒绝；端口 0 由系统分配。
- `POST /auth/register` → `201 {account, username}`，422 透传服务端字段级原因。
- `POST /auth/login` → `200 {account, username}`；token 进入共享会话组件（内存 + 会话文件），
  **绝不出现在本地接口响应、日志或插件侧**。
- 服务端不可达/超时 → `502 upstream_unavailable` / `504 upstream_timeout`，`fields: []`。
- 非约定路径 `404`，非 POST `405`，非法 JSON/缺字段 `422`（`code=required/type`）。
- 日志只输出监听地址与恢复状态，不打印密码或 token。

`dsh-plugin/` 侧只调用上面的本地路由，**必须显式设置** `BB_CLIENT_BASE_URL`
（例如 `http://127.0.0.1:8787`，Forge 插件没有默认值，且拒绝 `localhost` 别名/远程地址），
不直连 FastAPI、不重试、不接触任何会话凭据。

## 测试

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test integration_test -d linux
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client
```

- `test/` 61 例 + 1 个默认 SKIP 的真实链路用例：校验规则、真实 HTTP 桩上的 service
  行为、`GET /auth/session` 恢复路径（成功 / 401 清除 / 502 保留）、会话文件权限与内容
  （0600、无密码、替换失败保留旧记录、并发写不损坏、删除失败报错）、存储故障
  `session_storage_unavailable` 的登录/恢复/退出行为、本地控制接口（token 不外泄、
  502/504、存储故障不返回成功、回环限制）、宽/窄视口与键盘交互。
- `integration_test/auth_flow_test.dart`：Linux 上真实 HTTP 注册→复制账号→登录、
  错误密码 401、**重启恢复**、失效凭据清除、服务不可达保留提示、存储故障不报成功、
  宽窄视口切换。
  注：本机 Flutter 3.47 Linux device 在一次 `flutter test` 调用内启动第二个 App 会失败
  （`Error waiting for a debug connection`），因此所有桌面集成用例合并为一个
  `*_test.dart` 文件。

## 已知限制（本轮范围）

- 无 token 过期/刷新策略（本轮明确不做）；退出登录会清除本地凭据。
- 无找回密码、无资料页；登录成功只展示账号与退出操作。
- 未做 Android 真机验证（无设备，NOT RUN）；Windows 构建/运行未在本环境验证（无 MSVC，
  NOT RUN），`windows/` runner 与 Windows 会话目录仅做了静态配置。
- 退出登录没有服务端撤销接口（本轮不做），只清理本地凭据。
