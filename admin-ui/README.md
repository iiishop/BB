# BB 管理后台（Vue）

DEA-469 阶段 C 的 `admin-ui/`。消费阶段 A 的机器契约
[`server/contract/admin-openapi.json`](../server/contract/admin-openapi.json)
和 [`docs/contracts/dea469-admin-v1.md`](../docs/contracts/dea469-admin-v1.md)，
不另造身份、任务或 wire 定义。

- 构建产物：`dist/`（不提交），资源 base `/admin/`，API 相对 `/admin/api`。
- 由独立的 `bb-admin` 管理 origin 同源提供；业务监听不挂载管理页。
- 只含 Home、配置与登录/改密；Home 无统计或业务功能。

## 开发与校验

```bash
npm ci
npm run build        # 生产构建到 dist/
npm run typecheck    # vue-tsc --noEmit
npm test             # Vitest 单元/组件/契约测试
npm run test:e2e     # Playwright + 真实 bb-admin（见下）
```

`npm run verify` 依次执行 typecheck、test、build。CI 由 Forge 从仓库根接线；
本目录不修改共享 CI。

## 数据与安全约定

- 管理会话是 `HttpOnly` Cookie；CSRF 只保存在内存，刷新时重新 `GET /admin/api/session`。
  不使用 `localStorage`/`sessionStorage`/`document.cookie`（`tests/static-guards.test.ts` 防回归）。
- 所有变更请求使用 `credentials: 'same-origin'`、`X-BB-Admin: 1` 和内存中的
  `X-CSRF-Token`；没有 CORS 或 Origin 覆盖。服务端仍负责 Host/Origin/CSRF 校验。
- 页面不依赖内联脚本/样式或外部 CDN，兼容服务端 `default-src 'self'` CSP。
- 管理 API Token 是 write-only：仅作为提交参数进入内存，不回显、不落浏览器存储；
  刷新恢复使用 `GET /admin/api/tasks/current` 的 task_id，再向
  `POST /admin/api/tasks/{task_id}/authorization` 补交凭据（B/C 交接增量）。
- Vue 不持有任务真相：只展示服务端快照；断线不重建任务。双击由提交中守卫 +
  计划级幂等键约束；刷新从 `tasks/current` 恢复并从快照 `seq` 重新订阅 SSE。

## 阶段边界

阶段 A（当前基线 `8a99365`）只提供登录、会话、改密、登出。`public-config`、
`probes`、`plans`、`executions`、`tasks/*` 返回 `501 stage_b_not_implemented`。
配置页会明确显示“阶段 B 尚未接通”，并禁用会产生副作用的控件。

阶段 B 由 Forge 实现并提供 `/admin/` 静态挂载；本目录只按契约调用，不修改
`server/`。在 B 未接通前：

- **真实 A 路径**（登录、强制改密、旧会话/旧密码失效、刷新恢复、501 预览、
  登出）在真实 `bb-admin` 上验证。
- **B 交互路径**（探测胶囊、授权恢复、确认弹窗取消/执行、刷新恢复任务、
  计划 409 失效）由 Playwright 在浏览器路由层桩接 B 端点，与 A 的真实会话/鉴权
  分开，只作契约预览证据，不宣称端到端完成。

## 浏览器证据入口

`e2e/harness.py` 是**仅测试用**同源外壳：包住真实的 `create_admin_app`
（同一 Host/Origin/CSRF/Cookie 边界），在 `/admin/` 提供生产构建，并保持
`/admin/api/*` 不被 SPA fallback 吞掉。它不是产品代码，也不放宽任何安全头；
阶段 B 的正式挂载以 Forge 的实现为准。

`e2e/admin.spec.ts` 依次执行真实 A 流程和桩接 B 流程，截图写入
`.evidence/screens/`（已 gitignore）。运行前需要 Playwright Chromium：

```bash
npx playwright install chromium
npm run test:e2e
```

`e2e/prepare.mjs` 只清理 `admin-ui/.evidence` 与 `test-results` 下的旧产物，并为
每次运行创建隔离的管理数据库。

## 已知限制

- 阶段 B 未接通：没有真实 Cloudflare 账号/DNS/Tunnel，也没有真实公网副作用。
- 未验证真实 Arch 提权安装、Windows UAC/服务生命周期、真实设备浏览器；
  响应式证据是 1440×900 与 390×844 视口，不是移动设备。
- 桩接的 SSE 在快照后结束，页面会显示“实时连接中断”；真实 B 的流由服务端
  持续提供。
- 本目录自测不是独立 QA；最终验收由 Sentinel 在集成 SHA 上执行。
