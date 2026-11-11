BB STEP-1 的账号服务，Python 项目由 uv 管理。必须从同一仓库保留 `server/contract/`；该纯 Python 包只包含 DTO、校验及错误文案，同时供插件使用，不包含网络或数据库代码。

从仓库根目录启动（以下地址、端口、路径均为本机示例，可替换）：

```bash
uv sync --project server --locked
BB_DATABASE_PATH=./local-data/auth.db BB_HOST=127.0.0.1 BB_PORT=8000 uv run --project server --locked bb-server
```

Windows Git Bash 同样使用上述命令。三个环境变量均必填，不自动加载 `.env`。服务启动时事务性应用 `src/bb_server/migrations/001_auth.sql`，以 SQLite `user_version=1` 记录版本；已有数据不重建，遇到更高版本拒绝启动。

| 接口 | 成功响应 | 失败 |
| --- | --- | --- |
| `POST /auth/register` `{username,password}` | 201 `{account,username}` | 422 字段错误 / 503 存储暂不可用 |
| `POST /auth/login` `{account,password}` | 200 `{account,username,token}` | 401 账号或密码错误 / 422 / 503 |
| `GET /auth/session`，`Authorization: Bearer <token>` | 200 `{account,username}` | 401 请重新登录 / 503 |

按 Owner 补充与 Orion 修订，账号是安全随机分配的 `10000000–99999999` 数字字符串，冲突最多重试 100 次；禁止客户端指定，username 可重复且不参与登录。输入账号按八位 ASCII 数字检查，格式合法但不存在的账号统一返回 401。username trim 后 3–24 字符；密码不 trim，注册时至少 6 字符且同时包含 ASCII 大写、小写、数字，登录不再次检查复杂度。

默认 `PasswordHasher()` 生成 Argon2id 哈希。token 为随机 32 字节的 hex，`sessions` 只存其 SHA-256 摘要及账号外键、UTC 创建时间。选择 bearer token 是为了 Flutter 桌面/APK 与独立 Dart 客户端共用认证和重启验证；不实现过期、刷新或退出接口。会话凭据由客户端保管，插件不接收。无对应账号也执行一次默认 Argon2 验证；这不是完整的时序攻击审计。

`openapi.json` 为实际应用生成的接口快照，`contract/cases.json` 是服务端 HTTP 与 MCP 共同执行的 16 组可供 Dart 对照的输入样例（密码均为假数据）。样例中的 `fields` 对应 422，`normalized` 表示通过输入校验，不代表登录必成功。生成快照不启动服务、不访问数据库：

```bash
uv run --project server --locked python -m bb_server.export_openapi server/openapi.json
uv run --project server --locked pytest server/tests -q
```

备份使用 SQLite backup API，拒绝覆盖已有目标文件并检查完整性：

```bash
uv run --project server --locked python -m bb_server.backup ./local-data/auth.db ./local-data/auth-backup.db
```

恢复时先停服务，将 `BB_DATABASE_PATH` 指向备份文件再启动；保留原数据库以便回退。测试验证备份恢复后账号、会话仍可用。备份文件以 0600 权限创建（Windows 需由当前用户目录 ACL 保护）；数据库所在目录也应限制为服务运行用户访问。备份会恢复当时仍有效的会话，按敏感数据保管。

本轮仅覆盖本地账号流程，不包含公网部署、TLS、限流、全局请求体上限、会话过期或 Android 实机验证；服务不可宣称已经过公网安全加固。响应不回显密码，默认关闭 uvicorn 访问日志。不要启用会记录请求体或 Authorization 的代理日志。

实现参考：[FastAPI 错误处理](https://fastapi.tiangolo.com/tutorial/handling-errors/)、[argon2-cffi PasswordHasher](https://argon2-cffi.readthedocs.io/en/stable/howto.html)。依赖的精确版本见 `uv.lock`。
