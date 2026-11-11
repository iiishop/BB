# bb_client — BB Flutter client

Flutter 客户端，一套代码出 Linux/Windows 桌面与 Android APK。本轮（STEP-1）交付
**注册 + 登录**：两个响应式页面、一个可独立于 UI 运行的逻辑客户端入口，供 DSH MCP
插件调用。

```text
client/
  lib/main.dart            Flutter 入口（读取 BB_API_BASE_URL）
  lib/app.dart             设计 tokens、ThemeData、根 Widget
  lib/ui/                  登录 / 注册 / 注册成功 / 已登录 四个状态 + 响应式外壳
  lib/services/            认证 service、HTTP 客户端、客户端会话、本地控制接口
  lib/models/              DTO 与 {error:{code,message,fields}} 错误模型
  lib/validation/          与服务端一致的即时校验（仅提示，服务端是唯一判定方）
  bin/bb_client_api.dart   独立 Dart 逻辑入口（本地控制接口）
  test/                    widget/单元/真实 HTTP 桩测试
  integration_test/        Linux 桌面端到端用例
```

## 运行

```bash
flutter pub get
flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000
```

- 窄屏（< 960 逻辑像素）：单列，品牌头 + 全宽表单卡片，可滚动、SafeArea；
- 宽屏（>= 960）：左侧深青品牌面板 + 右侧 440px 表单列，窗口居中。

Linux 默认窗口 1180×780（`linux/runner/my_application.cc`）。Android 工程已就绪，
但本环境无模拟器/真机：Android 运行一律 **NOT RUN**，Linux 截图不代表 Android。

## 本地控制接口（给 dsh-plugin）

独立于 Flutter 视图运行，与页面共用同一个 `AuthService`、DTO、错误处理与会话组件：

```bash
dart run bb_client_api \
  --server-url http://127.0.0.1:8000 \
  --host 127.0.0.1 --port 8787
# 等价环境变量：BB_API_BASE_URL / BB_CLIENT_HOST / BB_LOCAL_API_PORT
```

- 只允许监听 `127.0.0.1`，非回环地址直接以退出码 64 拒绝；端口 0 由系统分配。
- `POST /auth/register` → `201 {account, username}`，422 透传服务端字段级原因。
- `POST /auth/login` → `200 {account, username}`；**token 由客户端会话持有，绝不返回**。
- 服务端不可达/超时 → `502 upstream_unavailable` / `504 upstream_timeout`，`fields: []`。
- 非约定路径 `404`，非 POST `405`，非法 JSON/缺字段 `422`（`code=required/type`）。
- 会话仅在内存中，进程退出即消失；插件不持有登录态。
- 日志只输出监听地址，不打印请求体、密码或 token。

`dsh-plugin/` 侧只调用上面的本地路由，配置项为其 client base URL（默认 `http://127.0.0.1:8787`），
不直连 FastAPI、不重试。

## 测试

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test integration_test -d linux
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client
```

- `test/` 41 例：校验规则、真实 HTTP 桩上的 service 行为、本地控制接口（token 不外泄、
  502/504、回环限制）、宽/窄视口的 widget 交互。
- `integration_test/auth_flow_test.dart`：Linux 上真实 HTTP 注册→复制账号→登录，
  错误密码 401，宽窄视口切换；同文件还注册了骨架的 Pipeline Smoke 用例。
  注：本机 Flutter 3.47 Linux device 在一次 `flutter test` 调用内启动第二个 App 会失败
  （`Error waiting for a debug connection`），因此所有桌面集成用例合并为一个
  `*_test.dart` 文件；`integration_test/support/` 只放注册函数。

## 已知限制（本轮范围）

- 无 token 持久化/刷新/过期策略，会话仅内存，退出即失效（本轮不做）。
- 无找回密码、无资料页；登录成功只展示账号与退出操作。
- 未做 Android 真机验证（无设备，NOT RUN）。
