BB STEP-1 账号、STEP-2 Profile 与 STEP-3 Chat 服务，Python 项目由 uv 管理。必须从同一仓库保留 `server/contract/`；该纯 Python 包只包含 DTO、校验及错误文案，同时供插件使用，不包含网络或数据库代码。

从仓库根目录启动（以下地址、端口、路径均为本机示例，可替换）：

```bash
uv sync --project server --locked
BB_DATABASE_PATH=./local-data/auth.db BB_AVATAR_DIRECTORY=./local-data/avatars BB_MEDIA_DIRECTORY=./local-data/media BB_HOST=127.0.0.1 BB_PORT=8000 uv run --project server --locked bb-server
```

Windows Git Bash 同样使用上述命令。以上五个环境变量均必填，不自动加载 `.env`。服务启动时事务性应用 `src/bb_server/migrations/001_auth.sql` 、`002_profile.sql` 和 `003_chat.sql`，以 SQLite `user_version=3` 记录版本；已有数据不重建，遇到更高版本拒绝启动。

| 接口 | 成功响应 | 失败 |
| --- | --- | --- |
| `POST /auth/register` `{username,password}` | 201 `{account,username}` | 422 字段错误 / 503 存储暂不可用 |
| `POST /auth/login` `{account,password}` | 200 `{account,username,token}` | 401 账号或密码错误 / 422 / 503 |
| `GET /auth/session`，`Authorization: Bearer <token>` | 200 `{account,username}` | 401 请重新登录 / 503 |

按 Owner 补充与 Orion 修订，账号是安全随机分配的 `10000000–99999999` 数字字符串，冲突最多重试 100 次；禁止客户端指定，username 可重复且不参与登录。输入账号按八位 ASCII 数字检查，格式合法但不存在的账号统一返回 401。username trim 后 3–24 字符；密码不 trim，注册时至少 6 字符且同时包含 ASCII 大写、小写、数字，登录不再次检查复杂度。

默认 `PasswordHasher()` 生成 Argon2id 哈希。token 为随机 32 字节的 hex，`sessions` 只存其 SHA-256 摘要及账号外键、UTC 创建时间。选择 bearer token 是为了 Flutter 桌面/APK 与独立 Dart 客户端共用认证和重启验证。STEP-2 增加服务端登出、每 30s HTTP 心跳、90s 离线状态与离线超过 24h 的会话清理；不实现固定 token 过期或刷新。会话凭据由客户端保管，插件不接收。无对应账号也执行一次默认 Argon2 验证；这不是完整的时序攻击审计。

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

本轮覆盖本地账号/Profile 与会话生命周期，不包含公网部署、TLS、限流、全局请求体上限或 Android 实机验证；服务不可宣称已经过公网安全加固。响应不回显密码，默认关闭 uvicorn 访问日志。不要启用会记录请求体或 Authorization 的代理日志。

实现参考：[FastAPI 错误处理](https://fastapi.tiangolo.com/tutorial/handling-errors/)、[argon2-cffi PasswordHasher](https://argon2-cffi.readthedocs.io/en/stable/howto.html)。依赖的精确版本见 `uv.lock`。


STEP-2 完整接口、错误、头像规范、六个本地接口与客户端接入规则见 `docs/contracts/profile-step2.md`。`GET /users/{account}/profile`、`PATCH /me/profile`、`POST/DELETE /me/avatar`、`GET /avatars/{account}.png` 均需 Bearer 鉴权。头像按 magic bytes + 实际解码校验，上传原始数据最多 5 MiB，归一化 PNG；默认 identicon 不落文件。`POST /auth/logout` 返回 204；`POST /auth/heartbeat` 返回 online 与 UTC last_seen_at。

`BB_SESSION_MAINTENANCE_SECONDS` 默认 5 秒（正有限数），控制后台会话维护频率；90 秒边界在下一次维护 tick 写入，认证/心跳也执行同一清理逻辑。维护任务在应用 lifespan 内启动/停止，存储暂时失败后下次 tick 重试。升级 STEP-1 时旧会话从迁移时间开始计时，不按旧 created_at 立即清理。

备份上传头像时须停止所有写入，执行上述数据库备份，并将 `BB_AVATAR_DIRECTORY` 的整个目录复制到同一备份集；恢复时同时配置还原的数据库与头像目录。只备份数据库不能恢复上传头像。测试验证了停写后的数据库+头像目录恢复。崩溃或旧文件删除失败可能留下孤立文件；应停写后按数据库引用核对清理，当前没有自动孤立文件清理任务。已引用文件缺失返回 503，不伪装为默认头像。

重新生成 HTTP 和本地接口 schema：

```bash
uv run --project server --locked python -m bb_server.export_openapi server/openapi.json --local-profile-output server/contract/profile-local-schema.json
```

存储锁竞争的事务边界、503 分类、实测数据、方案比较与重跑/撤回步骤见 `server/docs/storage-locks.md`。本轮保持 DELETE journal，不启用 WAL。

## 本机管理入口（DEA-469 阶段 A/B）

业务进程仍用上述 `bb-server`。新增的 `bb-admin` 是独立本机监听入口，不能挂到业务服务或 Tunnel 上。以普通用户启动，先设置与业务进程相同的 `BB_DATABASE_PATH`、`BB_PORT`，再设置独立管理路径和端口：

```bash
BB_DATABASE_PATH=./local-data/auth.db BB_PORT=8000 \
BB_ADMIN_DATABASE_PATH=./local-admin/admin.db BB_ADMIN_PORT=9001 \
  uv run --project server --locked bb-admin
```

管理入口固定为 `http://127.0.0.1:9001`（端口可配置；不要用 localhost 别名），拒绝跨源和代理转发请求，不读取 `BB_HOST` 或代理信任环境变量。数据库路径/端口必须与业务服务分离。管理身份初始 `admin/admin`，首次登录只能改密/查看会话/退出；新密码至少 12 字符，改密后所有旧会话失效，需重新登录。只支持本机 HTTP，Cookie/CSRF/Host 校验规则详见 `docs/contracts/dea469-admin-v1.md`；管理员并非普通 BB 用户。

先在 `admin-ui/` 运行 `npm ci --no-audit --no-fund` 和 `npm run build`，然后打开 `http://127.0.0.1:9001/admin/`。`bb-admin` 默认挂载 `admin-ui/dist`，可通过启动环境 `BB_ADMIN_UI_DIRECTORY` 指定绝对产物目录。业务服务没有管理路由；只增加短期随机实例挑战。公网草稿、只读探测、确认计划、持久任务、补交授权和 SSE 已实现；管理 API Token 只保留内存 15 分钟，刷新/重启通过当前任务恢复。

运行模式、全部共享状态写入入口、Cloudflare 权限、Arch/Windows 固定操作助手与验证边界见 `docs/contracts/dea469-public-v1.md`。普通用户运行 BB，助手单独经本机系统授权。没有专用云端授权时可使用只读检测和开发替身测试；不能把替身、下载校验或 Windows 请求验证当成真实安装/云端验收。

管理数据库创建为 POSIX 0600，独立新目录为 0700；已有父目录和 Windows 用户目录 ACL 由本机管理员保护。不要指向现有个人/生产数据库。管理员会话最长 8 小时；登录与改密共用每 60 秒 5 次的持久化预算。管理数据库和业务数据库分别备份，恢复旧管理备份会恢复旧密码及当时会话。

```bash
uv run --project server --locked pytest server/tests/test_admin.py server/tests/test_admin_http.py -q
uv run --project server --locked python -m bb_server.export_admin_openapi server/contract/admin-openapi.json
```
