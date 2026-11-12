DSH 的 stdio MCP 插件，保留 `register_account(username,password)`、`login_account(account,password)`，新增 `view_avatar`、`update_avatar`、`view_nickname`、`update_nickname`、`view_signature`、`update_signature`，共八个工具。所有调用经过独立逻辑客户端的本地 HTTP 接口，插件不调用远程服务端。Python 依赖由 uv 管理；保留相邻 `server/contract/` 以复用纯校验模块，不依赖或加载 FastAPI 服务端。

Profile 参数、六个本地路由和响应见 `docs/contracts/profile-step2.md`；机器可读 schema/样例在 `server/contract/profile-*.json`。头像读取返回真实 MCP image content，并附 account/版本元数据；每次调用都访问客户端，不做缓存。头像更新只转发唯一 path/url/base64 来源，文件读取、URL 下载、base64 解码和上传由客户端完成。更新工具不接受 account，不接收会话 token。

从仓库根目录安装并启动（本地客户端必须已经在所配置地址运行）：

```bash
uv sync --project dsh-plugin --locked
BB_CLIENT_BASE_URL=http://127.0.0.1:9187 uv run --project dsh-plugin --locked bb-dsh-plugin
```

`BB_CLIENT_BASE_URL` 必填，只接受 HTTP `127.0.0.1` origin，可配置端口；拒绝远程地址、localhost 别名、userinfo、路径、query、fragment。`BB_CLIENT_TIMEOUT_SECONDS` 默认为 10，可配置为正有限数。不会使用环境代理，不跟随重定向，不重试。每次调用创建并关闭独立 HTTP 客户端，cookie 不会跨调用保存。

配置到 DSH 的独立产品插件 profile（不要使用 Multica 开发 Agent 的 profile/凭据），按实际 DSH 配置表单填入以下进程参数；这描述 stdio 启动参数，不假定某个 DSH 配置文件格式：

| 配置 | 值 |
| --- | --- |
| Command | `uv`（或本机 uv 可执行文件） |
| Arguments | `run --project <BB 的本机路径>/dsh-plugin --locked bb-dsh-plugin`，逐参数填写 |
| Environment | `BB_CLIENT_BASE_URL=http://127.0.0.1:<本地客户端端口>` |
| Transport | stdio |

注册/登录成功 `structuredContent={account,username}`；错误 `isError=true, structuredContent={status,error}`，同时提供等价 JSON 文本。注册复用服务端的 ASCII 密码校验规则；登录只检查字段类型及账号格式。客户端负责会话和持久化，本地登录只返回账号和展示名。插件仍使用输出字段白名单，丢弃多余 token、cookie 和响应头；不在磁盘上创建登录态，不增加会话查询工具。

```bash
uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q
```

测试包括共享 `server/contract/cases.json`、`profile-cases.json` 及六个 Profile 工具、HTTP 故障/超时/重定向，以及真实 MCP 子进程 → 真实 loopback HTTP 监听器的传输测试；该监听器是测试替身，不能替代 Dart/FastAPI 集成验收。

在隔离的测试数据库上启动真实服务端与 Muse 的独立 Dart 客户端后，运行真实链路检查。它会创建两个假账户，不输出密码/凭据；返回 0 才表示调用通过：

```bash
BB_CLIENT_BASE_URL=http://127.0.0.1:9187 uv run --project dsh-plugin --locked python -m bb_dsh_plugin.smoke
```

该检查覆盖 MCP 列表、同名注册、登录、业务错误及输出字段；客户端重启恢复、401 清除凭据、网络失败保留凭据需在集成版本的客户端测试中验证。端口配置必须指向逻辑客户端；仅凭相同路由无法自动识别操作者误填的本机服务端端口。

未接入真实产品 DSH Runtime；标准 MCP stdio 已测试，不宣称 DSH 安装验收完成。实现采用[官方 MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)，版本固定在 `uv.lock`。

DEA-467 受保护查询模式
---------------------

`BB_CONSUMER_STATE_FILE` 可指向宿主管理的私有 `{owner_key,identity}` JSON。
该模式增加 list_conversations/get_message/get_context，read_messages 支持
前后定位；身份由宿主注入，查询不消费，内部 ACK/confirm 不向模型开放。
绑定变化后由宿主重启 MCP，旧实例不自动重绑或重试。未配置时保持 legacy
接口。完整路由、分页和退役策略见 `docs/contracts/dea467-query-v1.md`。
此 Python 接线不等同独立 DSH bundle 安装或真实 Dart 查询链路验收。
