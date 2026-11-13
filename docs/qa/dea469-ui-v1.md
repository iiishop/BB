# DEA-469 阶段 C：Vue 管理后台证据（authority rework v4）

- 接续基线：`15a617fb98d5c84f5071ed32428ea51940bdaeae`（r3），其父为固定集成基线
  `32f89632ce84d0a8238b5ef2f809400ff181610d`（保留 PR14/PR15）
- 分支：`agent/muse/dea469-r3`；仅写 `admin-ui/` 与本文件，未改 `server/`、PR15
  检查器、共享 CI、契约、锁文件或集成分支
- 环境：Arch Linux x86_64；Node 26.8.2；npm 12.0.2；Chromium 158.0.8127.18
  （Playwright 1.65）；Vue 3.5.x；Vite 8.3.8；TypeScript 5.9.3

## 本轮补充：busy/restoring 收尾归属（session-authority 完整性）

上一候选 `15a617f` 仍有源码缺口：`requestPlan` 在 `!sessionStillCurrent(epoch)` 分支
写 `error`；所有异步入口的 `finally` 无条件清空共享 `busy`，`restoreSession` 的
`finally` 无条件清空 `restoring`。因此旧 plan/restore/logout 的迟到收尾可能解除
**新会话/新操作**的 busy/restoring，或在退出后写迟到错误。本轮修正：

- `busy` 由 `beginBusy(action)` 分配单调 token，`endBusy(token)` 只清除自己拥有的
  token；`clearSession` 使 owner 失效。旧成功/错误/`finally` 不再清掉新操作 busy。
- `restoring` 同样由 `beginRestoring`/`endRestoring` token 拥有；旧 restore 的
  `finally` 不能解除新 restore。
- `logout` 捕获 session epoch：旧 logout 的迟到响应不写错误，其 `finally` 只在
  session 仍为发起时清除；不会清掉旧 logout 期间建立的新会话。
- `requestPlan` 先判 session，再判 task 归属；session 失效时直接返回，不写迟到
  error；task 归属失效时才写“任务已被更新”。
- 所有异步入口（restore/login/password/logout/save/probe/plan/execute/authorize）
  统一使用 token 收尾；正常完成仍清 busy/restoring，不改变既有成功路径。

## 已确认规则（与本轮共同边界）

### task-authority：旧任务授权响应不得夺取新任务

`authorizeTask`、`startProbe`、`confirmPlan`、`requestPlan` 捕获发起时 `task_id`
（无任务为 `null`）和 session epoch；响应返回时只有 `taskResponseStillOwned(owner)`
且 session 未变才应用。旧任务响应不再 `applyTaskAndStream`，不会关闭新 SSE。
`loadCurrentTask` 使用 `taskEpoch` + `taskReadSerial`，SSE 使用 `streamSerial`。

### config-authority：GET/PUT 乱序不得让配置版本倒退

唯一 `applyConfig` 写入配置：低于当前 version 的 GET/PUT 为 stale；相同 version
只合并更新的 `active.verified_at`，不改变 domain/draft；更高 version 才完整采纳并
失效旧计划。只有 newer 保存响应才清草稿并显示“已保存”，迟到保存不显示成功。

### session-authority：退出/失效后旧会话响应不得复活状态

`applySession`/`clearSession` 推进 session epoch；所有登录态异步写入口与收尾 token
均绑定。logout/401/改密后，迟到的 current/config/save/authorize/probe/execute 不能
写 task/config、创建 SSE、写迟到错误或清掉新操作的 busy/restoring。该规则是客户端
状态归属，不是服务端鉴权绕过。

## 写入/清空入口清单与共同修复点

| 入口 | 写入/清空 | 所有者与共同规则 |
| --- | --- | --- |
| `applySession` / `clearSession` / `handleUnauthorized` | session、CSRF、`sessionEpoch++`；clear 清全部状态、使 busy/restoring owner 失效 | 登录/恢复/退出/401/改密；所有在途响应与收尾 token 据此失效 |
| `beginBusy` / `endBusy` | busy、busyOwner | 所有异步操作的共享 busy；只清自己 token；正常完成仍清 |
| `beginRestoring` / `endRestoring` | restoring、restoringOwner | restoreSession 专用；旧 restore 不清新 restore |
| `reset` / `clearSession` | task/config/plan/draft/stream/busy/restoring | 会话生命周期终点 |
| `applyConfig` | config、configState、draft 清空、plan 失效 | 唯一 config 写入点，按单调 version 接收 |
| `loadConfig` / `saveDomain` | 经 applyConfig；save 另写 draft/notice/error | session epoch + version；迟到保存不显示成功 |
| `applyTask` | task、taskState、`taskEpoch++`、终态关流 | 唯一被采纳快照写入点；同任务旧 seq 拒绝 |
| `loadCurrentTask` | 经 applyTaskAndStream 或清 task/stream | session epoch + taskEpoch + taskReadSerial |
| `streamTask` | subscribeTask、streamState、streamSerial | 旧流事件/状态回调丢弃 |
| `startProbe` | task/stream、notice、busy | session epoch + 目标 task 归属 + busy token |
| `requestPlan` | plan、error/notice、busy | session epoch 先判；task 归属再判；busy token |
| `confirmPlan` | task/stream、plan、notice、busy | session epoch + task 归属 + config version + busy token |
| `authorizeTask` | task/stream、prompt、notice、busy | session epoch + task 归属 + busy token |
| `logout` | session/所有状态、busy | 仅当 session epoch 未变时 clear；迟到 finally 不清新会话 |
| `restoreSession` | restoring、session | restoring token；迟到 finally 不清新 restore |
| `setDomainDraft` / `discardDomainDraft` / `invalidatePlan` / `cancelPlan` | draft/plan/notice | UI 草稿边界；不改 config |

共同修复点：session epoch（会话归属）、task epoch/read/stream + task 归属（任务
归属）、`applyConfig` 单调 version（配置归属）、busy/restoring token（收尾归属）。
四者不能互相替代；分别建模、集中调用。修复规则不是“所有 finally 都不清”，而是
**只清自己拥有的操作**；正常操作完成仍释放自身 busy/restoring。

## 修前失败 → 修后通过

1. **固定基线 review probes（32f8963）**：`npm run test:review-probes` 经
   `qa_evidence.py run` → **4 failed / 0 passed，退出 1**（配置 GET/PUT、authorize
   seq 2/4）。产物 `before-probes/`（历史证据）。
2. **配对 before（b813c46，源码同 32f8963，仅测试）**：authority+admin-state →
   **33 tests，10 failed / 23 passed，退出 1**。产物 `before-authority/`。
3. **本轮 busy before（9783d6b，源码同 15a617f，仅测试）**：admin-state →
   **33 tests，4 failed / 29 passed，退出 1**：旧 plan 成功/失败写迟到错误或清
   busy、旧 restore 清 restoring、旧 logout 清新 session。产物 `before-busy/`。
4. **候选 after**：`npm test` **65 passed / 0 failed / 0 skipped（9 files）**；
   `npx vitest run tests/authority.test.ts tests/admin-state.test.ts` **37 passed**；
   `typecheck`、`build` 退出 0。产物 `after/`；对应 before 同一 classname/name。
5. review probes 已迁入 `tests/authority.test.ts` 并由默认测试收集；重复
   `review-probes/`、`vitest.review.config.ts`、`test:review-probes` 已删除，未
   skip/xfail 或放宽断言。

## QA evidence 与证据包

- 报告 `qa-r4-report.json`，规则 task-authority/config-authority/session-authority；
  session 使用本轮 busy 断言（before 9783d6b），task/config 使用 b813 配对 before。
- 证据包 `dea469-r4-evidence.tar.gz` 保留相对目录：`qa-r4-report.json`、
  `before-probes/`、`before-authority/`、`before-busy/`、`after/`、`browser/`、
  `check.log`、`full-tests.log`、`typecheck.log`、`build.log`。接收者可解包后直接运行
  `scripts/ci/qa_evidence.py check qa-r4-report.json --candidate <SHA> ...`。
- 本次将 runner 的 `run.json`、`junit.xml`、`output.log` 一起打包，不再只附报告/XML。
- checker 通过只证明证据一致性；入口覆盖与语义由 Sentinel 复核。

## 真实 UI 可达性

- **特定时序（挂载 ConfigView + 真实 store）**：
  `tests/config-view.test.ts` 新增“plan 在途 → logout/login → 新 probe 在途 → 旧
  plan 返回”，断言旧响应不写迟到错误、不把 busy 从 probe 清空；新 probe 完成后
  busy 正常释放。这是挂载组件可达性，不冒充浏览器 E2E。
- **通用产品浏览器流程（独立）**：
  `TMPDIR=... PLAYWRIGHT_BROWSERS_PATH=... node server/probes/public_browser.mjs`：
  **7 项快速回归 + 2 条产品入口流程通过，退出 0**；真实管理后端、SQLite、SSE、
  静态挂载参与。第二条场景云端/安装器/公网验证器为替身，不计真实云验收。分组
  报告，不互相替代。

## 未运行 / 限制

- 真实 Cloudflare/DNS/Tunnel、Arch 提权安装、Windows 真机/UAC/服务生命周期：
  NOT RUN；无本轮专用授权。
- 真实移动设备浏览器：NOT RUN；只有既有视口夹具截图。
- 独立 QA 未开始；未改 PR15 检查器、共享 CI、服务端、契约或锁文件；未合
  PR13/main、未部署、未发布、未置 Done。
