# DEA-469 阶段 C：Vue 管理后台证据（v1）

- 基线：`8a9936547e96aae70d5f7d951030160c020f4ca9`（Orion 集成分支 `agent/orion/1032cfd8e912` 当前 SHA）
- 交付分支：`agent/muse/0fcd2167262c`，只新增 `admin-ui/` 与本文件；未改 `server/`、共享 CI、`main`
- 环境：Arch Linux x86_64；Node 26.8.2；npm 12.0.2；Chromium 158.0.8127.18（Playwright 1.65）；
  Vue 3.5.x；Vite 8.3.8；TypeScript 5.9.3（`vue-tsc` 3.3.x 需要 TS 5，TS 7 会报 `lib/tsc` 导出缺失）
- 契约：`server/contract/admin-openapi.json` 1.0.0；`docs/contracts/dea469-admin-v1.md`；
  B/C 交接增量的 `POST /admin/api/tasks/{task_id}/authorization`（Forge 负责服务端实现）

## 本轮修复（Orion 反馈：执行幂等键）

上一候选 `bad880d` 在 `admin-state.ts` 使用 `exec:<plan_id>` 作为
`PlanExecute.idempotency_key`，不符合唯一契约的 UUID 格式；真实服务端会在执行前
返回 422。本次修复：

- 每个 `plan_id` 在页面会话内缓存一个 `crypto.randomUUID()`；同一计划的重试与
  双击复用同一 UUID，不同计划使用不同 UUID；双击仍由提交中守卫阻断。
- 新增契约回归：把界面实际生成的 `/executions` 请求体（含 `idempotency_key`）
  交给服务端规范 DTO `PlanExecute` 校验；旧 `exec:<plan_id>` 必须失败于
  `idempotency_key / uuid_parsing`，修复值必须通过。该回归在 `npm test` 内执行。
- 浏览器桩同步按 UUID 校验执行请求，旧值会得到 422，不再只比字段字符串。
- 原有取消、版本失效、刷新恢复、双击不重复等断言保留。

## 交付内容

`admin-ui/` 为独立 Vue 3 + TypeScript + Vite 应用，资源 base `/admin/`，API 相对
`/admin/api`。包含登录、强制改密、Home、配置页、单胶囊状态、可复用确认浮层、
authorization 恢复浮层、错误/断线/501 状态、1440×900 与 390×844 响应式布局。

- 管理会话只用 HttpOnly Cookie；CSRF 仅在内存，刷新重新 `GET /session`。
- 无 `localStorage`/`sessionStorage`/`document.cookie`/`v-html`/内联脚本或样式/外部 CDN；
  `tests/static-guards.test.ts` 程序化防回归。
- 管理凭据 write-only：确认浮层与授权浮层提交后立即清空，不进入任何浏览器存储或日志。
- 任务真相只在服务端：刷新从 `/tasks/current` 恢复，再按快照 `seq` 订阅 SSE；
  断线不重建任务，旧序列被忽略。
- 双击/重复确认：提交中守卫 + 计划级 UUID 幂等键（同一 plan_id 在页面会话内复用），
  单元测试与浏览器测试都验证只发出一次执行请求；浏览器桩按服务端规则把非 UUID
  幂等键视为 422，旧缺陷会被该层捕获。
- 计划取消不发任何执行请求；保存新域名/配置版本变化使未执行计划失效；服务端
  409 时清空确认并提示重新探测。

## 命令与结果（本机实跑）

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `cd admin-ui && npm ci --no-audit --no-fund` | 0 | 159 packages，干净安装 |
| `npm run typecheck` | 0 | `vue-tsc --noEmit` 无错误 |
| `npm test` | 0 | 6 个文件、**38 passed / 0 failed / 0 skipped**，758ms；JUnit：`.evidence/vitest-junit.xml` |
| `npx vitest run tests/contract-execute-body.test.ts` | 0 | **2 passed**；实际请求体：合法 UUID 通过，旧 `exec:<plan_id>` 在 `idempotency_key / uuid_parsing` 失败 |
| `npm run build` | 0 | 44 modules；`dist/index.html` 0.45 kB、CSS 13.36 kB、JS 131.15 kB |
| `npm run test:e2e` | 0 | **1 passed**，3.7s；JUnit：`.evidence/playwright-junit.xml`；12 张截图 |

`npm test` 的规范 DTO 回归优先使用 `server/.venv` 的 Python，否则执行
`uv run --project ../server --locked python`；CI 的 admin-ui job 需安装 uv 或用
`ADMIN_UI_PYTHON` 指向带 pydantic 的解释器。

浏览器测试使用真实生产构建 + 真实 `bb-admin`（阶段 A 应用），在
`127.0.0.1:9477` 同一管理 origin 上运行。`admin-ui/e2e/harness.py` 是仅测试用的
同源静态外壳：直接包住 `create_admin_app`，保持 Host/Origin/CSRF/Cookie 边界与
安全头不变；`/admin/api/*` 不会被 SPA fallback 吞掉。它不是产品代码，正式挂载由
Forge 在阶段 B 提供。

### 真实 A 证据（无 B 桩）

- 新实例 `admin/admin` 登录 → 仅出现强制改密页（无侧边栏导航可绕过）。
- 改密后所有会话失效、回到登录页；旧密码登录被拒（真实 401）；新密码可登录。
- 刷新页面从 `/session` 恢复登录态；配置页真实收到
  `501 stage_b_not_implemented` 并显示“阶段 B 尚未接通”，不产生外部副作用。
- 退出登录回到登录页。
- 截图：`01-login`、`02-forced-password-change`、`03-password-rotated-relogin`、
  `04-home`、`05-config-real-backend-501`。

### B 契约预览证据（真实 A 会话 + 浏览器路由桩接 B）

Playwright 只对 B 端点（`public-config`、`probes`、`plans`、`executions`、
`tasks/current`、`tasks/{id}/authorization`、SSE）做路由级桩；A 的登录/会话/CSRF/
Cookie/501/登出仍是真实服务端。**不据此宣称端到端完成。**

- 保存域名草稿（v3→v4）后仍显示“尚未生效”，草稿与 active 分离。
- 只读探测 → 单胶囊 `awaiting_authorization/unknown` + “补充管理凭据”动作。
- 授权浮层提交 write-only token → `POST /tasks/{id}/authorization` 一次，任务恢复为
  `finished/passed` 并给出服务端允许动作 `create_and_connect`。
- “创建并连接 Tunnel”弹出确认浮层，列出域名、服务端选择的目标、资源意图、
  公开范围、风险；取消后 **executions = 0**。
- 再次打开并双派发点击 → **executions = 1**；请求带同一计划的
  `plan_id`/`digest`/`config_version`，幂等键为合法 UUID（同一 plan_id 复用；旧 `exec:<plan_id>` 已由契约回归显式拒绝）。
- 刷新页面：`/tasks/current` 返回终态快照，胶囊显示“公网验证通过”，资源标为
  “本次创建”，**没有新建任务/重复执行**（executions 仍为 1）。
- 保存新域名后打开新计划；服务端版本在确认前前进 → 执行返回 409，浮层关闭并
  提示“服务端拒绝了本次执行”，旧确认不可执行。
- 截图：`06-capsule-awaiting-authorization`、`07-confirm-plan`、
  `08-task-queued-after-confirm`、`09-refresh-restored-terminal-task`、
  `10-stale-plan-rejected-409`、`11-mobile-home`、`12-mobile-config`。
- 桩接 SSE 在发送一次快照后结束，页面因此显示“实时连接中断”（真实 B 的流应持续）；
  该提示是桩的已知表现，不影响刷新恢复断言。

## 验收映射

- **验收 4**：取消确认无副作用（单元测试断言 0 次执行；浏览器断言 executions=0）；
  域名/版本变化使旧确认失效（单元测试保存域名清空计划；浏览器 409 路径）。
- **验收 6**：双击只产生一次执行（单元 + 浏览器）；刷新从 `/tasks/current` 恢复
  并续订 SSE，断线不重建任务；旧 `seq` 事件被忽略（单元测试）。
- **验收 10**：真实 A 的登录/改密/刷新/501/登出 + B 契约预览截图，真后端与桩分列；
  Home 仅欢迎内容，无统计或业务功能。
- **验收 11（前端部分）**：`npm ci`、`typecheck`、`test`、`build` 稳定入口供 Forge 接入
  共享 CI；本分支未改 CI。

## 未运行 / 限制

- 阶段 B 服务端未接通（当前返回 501）：无真实公网配置、探测、Tunnel、DNS、
  Cloudflare API 或鉴权副作用；B 端点全部为浏览器桩。
- 真实 Cloudflare 账号/DNS/资源授权、Arch 提权安装、Windows 真机/UAC/服务生命周期：
  NOT RUN。无专用测试凭据，不读个人凭据、不改系统服务。
- 真实 Android/iOS/Windows 浏览器与设备：NOT RUN；响应式仅为 1440×900、390×844
  视口截图。
- 真实 SSE 长连接、自动重连与终态事件顺序：NOT RUN（桩只返回一次快照）。
- 未做独立 QA；本文件是开发定向自测。最终由 Sentinel 在 Orion 集成 SHA 上复验。
- `admin-ui/e2e/harness.py` 只服务浏览器证据；Forge 的 `/admin/` 正式静态挂载完成
  后应改用真实入口复跑同一浏览器脚本。
