## 结论与边界

本次针对 Owner 的持锁反例，基线为 `51d0d8d1b43c5a326b824f170b539f79ab775326`，只修改 `server/`。不启用 WAL，不改变 schema/user_version=3，不改变现有数据目录和部署。

最小复现不需要高并发：**一个进程对同一个 SQLite 文件执行 `BEGIN IMMEDIATE` 并保持事务，另一个进程处理一个登录请求**即可。登录验密后的 session INSERT 等待 SQLite 的 1 秒 busy timeout，然后抛出 SQLITE_BUSY(5)。基线 `/users` 在鉴权后无条件 `BEGIN IMMEDIATE` 做在线状态维护，因此新鲜会话的纯列表轮询也争夺写锁。异常 handler 将 BUSY、IO 和其他错误合并且不记请求日志，掩盖了区别。这里不是已证明的磁盘故障，也没有证据证明已确认消息丢失。

本机实测 Linux、Python 3.13.15、SQLite 3.53.1、`/dev/sda3` 上 ext4（rw,relatime）、DELETE journal。外部持锁持续超过写请求进入 SQLite 后的 1 秒，基线即失败；单登录请求已足够。网络文件系统、Windows 文件锁及其他 SQLite 版本没有实测，不能从本机数字外推。没有外部持锁时是否失败取决于实际事务重叠；Owner 的零失败对照与本机压力数字均保留，不用“并发高”代替锁证据。

## 方案选择

| 方案 | 收益 | 成本/局限 | 回滚 |
| --- | --- | --- | --- |
| 单纯增加 timeout，或整请求重试 | 可吸收更长的短暂竞争 | 仍让列表抢写锁；线程等待更久；整请求重放会重做 token/文件等副作用，外部长期持锁仍失败 | 代码回滚容易，但不选整请求重试 |
| WAL | 可降低读者与写提交之间的互相阻塞 | 仍只有一个 writer，不能解决另一个进程的 BEGIN IMMEDIATE；需要 sidecar、checkpoint、备份/部署兼容验证 | 需停写、checkpoint 和 journal 模式切换；本轮不选 |
| **明确读/写事务 + 边界上的有界退避（采用）** | 列表不再申请写锁；在业务执行前取得读快照/写锁；COMMIT BUSY 重试同一事务，不重复业务 | 每个事务最多约 3 秒竞争预算；不保证公平/无限负载；读写仍受 DELETE journal 协议约束 | 仅代码回滚，无数据迁移 |
| 请求/写入排队 | 可令单进程 writer 顺序执行，减少自竞争 | 队列需容量、取消、超时、跨 worker 协调；不控制外部持锁进程，重启持久性另需设计 | 需排空队列、停止接受新任务；本轮不引入 |

这不是仅将 timeout 从 1 改成 3。SQLite 连接自身 timeout=0；统一连接入口区分 `write=True` 和 query-only 读快照，业务体只执行一次。重试仅限 SQLITE_BUSY 的三个持久边界：`BEGIN IMMEDIATE`、读快照首次取得（`SELECT rootpage FROM sqlite_schema LIMIT 1`）、`COMMIT`。指数退避从 10ms 上限开始，封顶 100ms，每次取该上限的 1/2～1 倍抖动。一个 monotonic deadline 覆盖该事务的获取、业务耗时和提交，不在 COMMIT 重新发放预算。

COMMIT 返回 BUSY 时事务仍在，保留同一事务重试；耗尽预算则 rollback 后返回 503。IO、SQLITE_LOCKED 及其他错误不自动重试。消息、operation、两个账号事件仍在同一事务中；成功响应在 COMMIT 后。重试不重新生成消息、不再次执行文件写入，不宣称外部 IO 故障具备天然 exactly-once。

读事务先取得 SHARED 快照再进入业务读取，避免只重试写锁而漏掉 PENDING/EXCLUSIVE writer 阻塞读取的情况；query_only 防止隐式读写升级。头像读取仍与头像替换串行，以保留跨 worker 文件归属保证。`/users` 用 last_seen_at 边界计算在线状态；后台维护、心跳与到期认证维护仍持久化状态。**当认证发现会话维护已到期，鉴权仍可能需要写锁**；不以绕过到期清理换取 200。

长期外部持锁无法被应用安全“修掉”：写请求约 3 秒后仍应失败，不抢夺别的进程锁、不确认未提交的数据。3 秒是事务锁竞争预算，不是端到端 HTTP SLA；密码验证、多个事务、文件 IO 或操作系统暂停另计。运维应检查长期持锁进程/长事务。此选择不会保证任意压力下零 503。

## API 与日志

保留 HTTP **503**、`{error:{code,message,fields:[]}}`；仅细分 code，现有按 HTTP 503 处理的客户端无需改动。已更新共享 ErrorDetail 描述与 `server/openapi.json`。

| code | 条件 | 行为 |
| --- | --- | --- |
| `storage_busy` | SQLite BUSY / LOCKED | `Retry-After: 1`；提示调用方稍后重试，非无限自动重试承诺 |
| `storage_io_error` | OSError，或 SQLite IOERR/CANTOPEN/FULL/READONLY | 不自动重放；检查存储条件 |
| `storage_unavailable` | 其他 SQLite 错误 | 保留原 fallback；检查错误类别 |

请求失败日志 `storage_failure` 含 category、公开 code、HTTP method、**路由模板**、SQLite 数字错误码/errno、阶段、尝试次数与等待毫秒数。后台使用 method=background、route=session_maintenance。恢复日志 `storage_lock_retry` / `storage_lock_recovered` 记录边界与等待；不输出异常原文、文件路径、SQL 参数、账号、token、请求体或 query string。

消息提交结果未知时先用当前认证账号查询 `/operations/{operation_id}`；已成功取回原结果，404 才以相同 nonce/operation_id 和相同内容有界重试。不能因为看到 IO 503 就盲目生成新 nonce。登录当前没有业务幂等键，本轮不将客户端跨 HTTP 的登录重放声明为幂等。

## 修复前后实测

下面每个持锁条件/路由均执行三次。脚本的 1.5 秒是计划释放时刻，若 HTTP 提前失败/成功则提前清理锁进程；pytest 的登录回归则固定从写入口持锁 1.3 秒后释放。持续持锁条件在收到 HTTP 结果后才释放。

| 条件/请求 | 基线 | 最终实现 |
| --- | --- | --- |
| 持锁直到响应，POST /auth/login | 3×503，1.0620–1.0653s | 3×503 storage_busy，3.0629–3.0646s，明确日志 |
| 持锁直到响应，GET /users | 3×503，1.0049–1.0053s | 3×200，0.0027–0.0034s |
| 持锁直到响应，POST /messages | 3×503，1.0054–1.0060s | 3×503 storage_busy，3.0031–3.0037s |
| 计划持锁 1.5s，POST /auth/login | 3×503，1.0605–1.0641s | 3×200，1.5315–1.5844s |
| 计划持锁 1.5s，GET /users | 3×503，1.0050–1.0053s | 3×200，0.0027–0.0035s |
| 计划持锁 1.5s，POST /messages | 3×503，1.0051–1.0054s | 3×200，1.5375–1.5794s |

14 线程/15 秒混合真实 HTTP 对照（无外部锁，每个线程顺序轮换 users/session/messages，synthetic 账号）：

| | /users 200/503 | /auth/session 200/503 | /messages 200/503 | 总计 |
| --- | --- | --- | --- | --- |
| 基线 | 883/2 | 883/1 | 857/26 | 2652 请求，30 个 503 |
| 最终 | 772/0 | 771/0 | 766/0 | 2309 请求，0 个 503 |

这不是吞吐提升证明，也不是 Owner 原机器压测的同一数据。保留一次中间实现的 6 个 503（读快照尚未前置取得，且当时并行运行 pytest）；没有拿单次绿色结果掩盖该迭代失败。最终单独运行 HTTP 对照。最终数据库包含 769 messages、769 operations、1538 events：其中 3 条来自短暂锁恢复用例，766 条来自压力对照。

## 可复现命令与回归

从仓库根目录运行，证据输出目录必须不存在：

```bash
uv sync --project server --locked
uv run --project server --locked pytest server/tests -q --tb=short
uv run --project server --locked python server/probes/storage_lock_http.py --evidence ./storage-evidence
uv run --project server --locked ruff check server/src server/contract/src server/probes/storage_lock_http.py server/tests/test_storage_locks.py
```

HTTP 探针启动/收回自己的真实 FastAPI 与持锁进程；不读个人 profile。`--data-parent PATH` 可指定隔离数据库所在文件系统，summary 记录实际 FSTYPE/SQLite/journal。脚本需要 `findmnt`（Linux）；Windows 原生执行该脚本未验证。证据目录中的 `bb-storage-*` 含假账号数据库/令牌摘要，属于私有工作资料，**不要作为交付附件**；交付仅 summary、server.log 和命令日志。探针 exit0 表示完成测量，不意味着所有请求都返回 200，故意持锁的 503 必须保留。

用同一新增回归断言证明旧基线失败（下例从仓库根目录执行，路径不要复用已有 checkout）：

```bash
git worktree add --detach ../storage-before 51d0d8d1b43c5a326b824f170b539f79ab775326
PYTHONPATH=../storage-before/server/src:../storage-before/server/contract/src uv run --project server --locked pytest server/tests/test_storage_locks.py -k 'users_read_succeeds or login_recovers' -q --tb=short
```

实际旧基线结果为 **2 failed / exit1**，均为预期 200、实际 503；修复后同断言通过。若要重跑旧 HTTP 数字，用相同 PYTHONPATH 前缀执行上面的 HTTP 探针，其子服务继承该源代码路径。

新增确定性测试覆盖：独立持锁进程下纯读；超过旧 1 秒窗口的登录恢复；独占锁下读快照恢复；预算耗尽不新增 session；真实 SHARED reader 迫使 COMMIT BUSY、业务体只执行一次；COMMIT 预算耗尽回滚；8 路相同 nonce 重放、完成后查询/重放仍为 1 message/1 operation/2 events；IO/其他分类且日志不泄密。IO 分类使用明确的异常注入，不冒充物理磁盘损坏实验。

原 105 条 server 测试保留（两处原 BUSY 错误码断言更新为 storage_busy），包含 migration、backup、Profile、presence、权限、媒体、事务与契约快照。最终 `uv run --project server --locked pytest server/tests -q --tb=short` 为 **115 passed / exit0（38.14s）**；完整 SHA 见交接评论和证据 manifest。限定生产代码/共享契约/新增探针与测试的 ruff 检查 exit0；尝试 `ruff check server` 得到原有 fixture 未使用导入和测试导入顺序共 12 项，exit1，没有为此改写历史 QA 夹具。首次新测试运行 112 passed / 2 failed 是测试假 password 未满足原库 CHECK 约束，修正假数据后重跑，原始失败日志也交付。

## 安装、备份与回滚

在独立 checkout 应用本分支，`uv sync --project server --locked`；用自己的隔离数据目录设置 `BB_DATABASE_PATH`、`BB_AVATAR_DIRECTORY`、`BB_MEDIA_DIRECTORY`、`BB_HOST`、`BB_PORT` 后执行 `uv run --project server --locked bb-server`。本轮没有修改全局安装、个人部署或现有服务。

没有 WAL PRAGMA、没有 WAL 模式迁移、没有新增 `-wal`/`-shm` 生命周期。DELETE journal 原有临时 `-journal` 仍由 SQLite 管理。数据库目录仍需 SQLite 创建 journal 的写权限。`backup.py` 仍使用 SQLite backup API；现有备份与迁移测试一并运行。**这不等于完成 WAL 部署验证**；若未来采用 WAL，须另行验证 checkpoint、sidecar、备份/恢复与文件系统兼容，不能只复制主 db 文件冒充一致备份。

数据库备份命令不变：`uv run --project server --locked python -m bb_server.backup SOURCE DEST`。媒体/头像仍需在停写后和 DB 一起保存，当前 backup API 不自动复制附件文件。撤回时停止该隔离实例、切回基线代码再启动；没有新持久 schema 要降级。不删除数据库、不手动移除正在使用的 SQLite journal 文件。

本轮不重做 Flutter、Android/Windows 运行、真实模型/视觉及完整 DSH 故障矩阵，均为 NOT RUN；后续独立 QA 须固定本次完整 SHA。保持 in_progress 与当前 assignee，不合 main、不发布、不标 Done。
