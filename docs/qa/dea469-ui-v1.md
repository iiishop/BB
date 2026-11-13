# DEA-469 阶段 C：Vue 管理后台证据（authority rework v3）

- 固定基线：`32f89632ce84d0a8238b5ef2f809400ff181610d`（保留 PR14/PR15）
- 分支：`agent/muse/dea469-r3`；仅写 `admin-ui/` 与本文件，未改 `server/`、PR15
  检查器、共享 CI、契约、锁文件或集成分支
- 环境：Arch Linux x86_64；Node 26.8.2；npm 12.0.2；Chromium 158.0.8127.18
  （Playwright 1.65）；Vue 3.5.x；Vite 8.3.8；TypeScript 5.9.3

## 本轮必要规则与修复

### task-authority：旧任务授权响应不得夺取新任务

`authorizeTask` 在 await 期间可能：Escape 关闭授权弹窗、旧任务 SSE 结束、其他标签
启动新任务、当前页刷新采纳新任务。旧响应返回时不得覆盖 `task` 或关闭/替换新通道。

修复：mutation 响应绑定发起时的任务归属。`authorizeTask`、`startProbe`、
`confirmPlan`、`requestPlan` 捕获 `task_id`（无任务时为 `null`）和 session epoch；
响应返回时只有 `taskResponseStillOwned(owner)` 且 session 未变才应用。旧任务响应
不再 `applyTaskAndStream`，不会关闭新 SSE。所有入口共用同一归属 helper，不按
单个 task_id 写特判。

### config-authority：GET/PUT 乱序不得让配置版本倒退

`loadConfig` 与 `saveDomain` 都可能晚于更新快照返回。修复集中在
`applyConfig`（配置状态的唯一写入点）：

- 低于当前 `version` 的快照一律 stale；
- 相同 version 只允许合并更新的 `active.verified_at`，不得改变 domain/draft；
- 更高 version 才完整采纳并失效旧计划。
- `saveDomain` 只在新快照被采纳时清空草稿并显示“已保存”；迟到/落后响应提示
  页面保留较新版本，不显示失实保存结果。

`config.value` 的写入仅剩 `applyConfig`（以及 `clearSession` 清空），避免 GET/PUT
各自一套判断。

### session-authority：退出/失效后旧会话响应不得复活状态

`applySession` 推进 `sessionEpoch`；`clearSession`（logout、401、改密后）同样推进。
所有登录态异步写入口捕获 epoch，返回时 `sessionStillCurrent` 不成立即丢弃：

- `loadCurrentTask` / `loadConfig`（成功与失败分支）
- `saveDomain`（不写 config、不显示保存成功）
- `startProbe` / `requestPlan` / `confirmPlan` / `authorizeTask`
- `restoreSession` / `login` / `changePassword`

会话失效后迟到响应不能写 task/config、不能创建 SSE、不能写迟到错误。该边界是
客户端状态归属，不是服务端鉴权绕过。

## 写入/清空入口清单与共同修复点

| 入口 | 写入/清空 | 所有者与共同规则 |
| --- | --- | --- |
| `applySession` | session、CSRF、`sessionEpoch++` | 登录/恢复会话；所有异步响应靠它判新旧会话 |
| `clearSession` / `handleUnauthorized` | session/config/task/plan/draft/stream 全清、`sessionEpoch++` | logout、401、改密；让所有在途响应失效 |
| `applyConfig` | config、configState、draft 清空、plan 失效 | 唯一 config 写入点，按单调 version 接收 |
| `loadConfig` | 经 `applyConfig` | session epoch + version；落后 GET 不写 |
| `saveDomain` | config（经 applyConfig）、draft、notice/error、busy | session epoch + version；只有 newer 才报保存成功 |
| `applyTask` | task、taskState、`taskEpoch++`、终态关流 | 唯一被采纳快照写入点；同任务旧 seq 拒绝 |
| `loadCurrentTask` | 经 `applyTaskAndStream` 或清空 task/stream | session epoch + `taskEpoch` + `taskReadSerial` |
| `streamTask` | subscribeTask、streamState、`streamSerial` | 旧流事件/状态回调按 stream serial 丢弃 |
| `startProbe` | task/stream、notice、busy | session epoch + 目标 task 归属 |
| `requestPlan` | plan、error/notice、busy | session epoch + 目标 task 归属 + config version |
| `confirmPlan` | task/stream、plan、notice、busy | session epoch + 目标 task 归属 + config version |
| `authorizeTask` | task/stream、authorizationPrompt、notice、busy | session epoch + 目标 task 归属 |
| `setDomainDraft` / `discardDomainDraft` / `invalidatePlan` / `cancelPlan` | draft/plan/notice | UI 草稿边界；不改 config |

共同修复点：session epoch（会话归属）、task `taskEpoch/readSerial/streamSerial` +
`taskResponseStillOwned`（任务归属）、`applyConfig` 单调 version（配置归属）。三者
不能互相替代：退出不改变配置 version；旧任务响应与新配置快照不是同一所有权；
配置 version 也不能证明任务归属。因此分开建模、集中调用。

## 修前失败 → 修后通过

### 1. 固定基线 review probes（独立 requirement）

干净基线 `32f89632ce84d0a8238b5ef2f809400ff181610d`，通过
`scripts/ci/qa_evidence.py run` 执行 `npm run test:review-probes`：
**4 failed / 0 passed，退出 1**，对应两个 P2（配置乱序 2 例、authorize 旧响应 2 例）。
产物：`qa-r3-before-probes/`（run.json、junit.xml、output.log）。

### 2. 配对 before 证据（同一 testcase 名）

为让 review probes 进入默认回归后仍能配对，先在**仅测试**提交
`b813c463d34b9010be4c622b2611a2e3bcb32ef8`（源码与上述基线一致）加入
`tests/authority.test.ts` 与 session/mutation 回归，并用同一 runner 执行：

```bash
npx vitest run tests/authority.test.ts tests/admin-state.test.ts --reporter=junit
```

结果：**33 tests / 10 failed / 23 passed，退出 1**。失败覆盖：
配置 GET-before-PUT、PUT-before-GET；authorize seq=2/4；迟到 probe、迟到 execute、
迟到 save；logout 后 current/config、save、错误回调。产物：
`qa-r3-before-authority/`。

### 3. 候选通过

```bash
npm test                             # 9 files, 60 passed / 0 failed / 0 skipped
npx vitest run tests/authority.test.ts tests/admin-state.test.ts
                                     # 2 files, 33 passed
npm run typecheck                    # 退出 0
npm run build                        # 退出 0；JS 135.04 kB
```

`review-probes` 的相同断言已迁入 `tests/authority.test.ts`，默认 `npm test` 收集；
重复的 `review-probes/authority.test.ts`、`vitest.review.config.ts` 与
`test:review-probes` 脚本已删除。没有 skip/xfail，断言未放宽。

### 4. 真实 UI 可达性

`TMPDIR=<workspace>/tmp PLAYWRIGHT_BROWSERS_PATH=<workspace>/.pw-browsers node server/probes/public_browser.mjs`：
**7 项快速回归 + 2 条产品入口流程通过，退出 0**；`page_errors`、CSP violations
均为空。真实管理后端、SQLite、SSE、静态挂载参与。第二条场景仅云端/安装器/
公网验证器为替身，不计真实云验收。产物：`server/.evidence/browser-b-*`（随附件）。
组件挂载、store 替身和浏览器 E2E 分开报告，不互相冒充。

## QA evidence

- 报告与 runner 目录：`qa-r3-report.json`、`qa-r3-before-probes/`、
  `qa-r3-before-authority/`、`qa-r3-after-authority/`（workspace 隔离目录，附件交付）。
- 三项规则均以 `--require` 与 `--require-regression` 校验；`before` 使用同一
  classname/name。检查器通过只证明证据一致性，入口覆盖/语义仍由独立 QA 复核。
- 候选 SHA、CI 与最终 checker 输出以回复/附件为准；本文件不把本地测试当作 CI。

## 未运行 / 限制

- 真实 Cloudflare/DNS/Tunnel、Arch 提权安装、Windows 真机/UAC/服务生命周期：
  NOT RUN；无本轮专用授权。
- 真实移动设备浏览器：NOT RUN；仅有既有 1440×900/390×844 夹具截图。
- 独立 QA 未开始；未改 PR15 检查器、共享 CI、服务端、契约或锁文件；未合
  PR13/main、未部署、未发布、未置 Done。
