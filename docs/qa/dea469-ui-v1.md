# DEA-469 阶段 C：Vue 管理后台证据（review fixes v2）

- 固定基线：`2fe1320d2d49bc3a6f90715504efeb22104d0c9a`（含 PR14，保留其 CI 修复）
- 分支：`agent/muse/dea469-r2`，仅写 `admin-ui/` 与本文件；未改 `server/`、共享 CI、
  `main` 或集成分支
- 环境：Arch Linux x86_64；Node 26.8.2；npm 12.0.2；Chromium 158.0.8127.18
  （Playwright 1.65）；Vue 3.5.x；Vite 8.3.8；TypeScript 5.9.3

## 本轮修复（PR13 review 第 1–3 项）

### 1. 任务读取/SSE 归属（`admin-ui/src/stores/admin-state.ts`）

根因：`/tasks/current` 延迟返回时只按“同 task_id 的 seq”比较，不同旧 task_id
会被无条件接收；finished 快照还会关闭新 execution 的 SSE。旧 stream 的回调也未
绑定到具体 stream。

修复：所有任务接收入口共用一套时序/归属规则，不再靠 task_id 特判。

- 每个被接受的权威快照推进 `taskEpoch`；`/tasks/current` 请求捕获启动时的
  epoch，返回时若 epoch 已变化则丢弃该读取。
- `taskReadSerial` 只允许最新一次 `/tasks/current` 应用结果；并发读取的旧响应
  不会覆盖新响应。
- 每条 SSE 有独立 `streamSerial`；流关闭/替换后，迟到的事件和连接状态回调都被
  忽略，finished 旧读取也不能关闭新任务流。
- 直接 mutation 响应仍为权威；`applyTaskAndStream` 仅在快照被接受时重订流。

永久回归（`admin-ui/tests/admin-state.test.ts`）：

- “ignores a delayed /tasks/current read after a newer execution owns the stream”：
  延迟旧 probe 读取不得替换新 execution、不得增加 stream close；新任务后续 SSE
  事件与 authorization 请求仍使用新 task_id。
- “lets only the newest concurrent /tasks/current request apply its snapshot”。
- “ignores late events from a replaced task stream without task-id special cases”。

### 2. 安装成功文案（`admin-ui/src/lib/labels.ts`）

根因：`taskHeadline` 对任何 `finished/passed` 任务都显示“公网验证通过”，包括
server 安装完成后直接返回的 install-only 任务。

修复：只有 `checks` 中 `instance` 检查实际 `passed` 时才显示“公网验证通过”；
`installation` 检查 passed 显示“安装完成”；其余 finished/passed 显示
“只读检查完成”或“任务已完成”。安装成功不再声称公网验证成功。

永久回归（`admin-ui/tests/labels.test.ts`，3 项）：install-only、installation-only
与 instance passed/unverified 四种事实的文案分离；`StatusCapsule` 组件断言同步更新。

### 3. 未保存域名草稿边界（`admin-ui/src/stores/admin-state.ts`、`ConfigView.vue`）

根因：域名输入只存在视图内；用户输入新域名但未保存时，仍可基于旧保存版本探测/
生成计划，确认弹窗显示旧域名，容易被误认为使用新域名。

修复：草稿进入 store，明确“未保存草稿 / 已保存配置”边界。

- `setDomainDraft` / `discardDomainDraft` / `draftDirty`；草稿修改使未执行计划失效。
- 草稿未保存时阻止只读探测、生成计划和确认执行；允许 authorize/local_admin 等
  恢复动作。
- 保存新域名后 `task.config_version !== config.version` 时，计划动作被禁用并提示
  重新探测；服务端契约不变。
- ConfigView 显示“域名草稿尚未保存”提示、保存/放弃修改按钮，并禁用计划按钮；
  空探针按钮也受草稿边界约束。

永久回归：

- `admin-ui/tests/admin-state.test.ts`：“blocks probe, plan and execute while a
  domain draft is unsaved”；“requires a new probe before planning against a newly
  saved domain version”。
- `admin-ui/tests/config-view.test.ts`：未保存草稿点击旧计划动作时
  `createPlan` 调用数为 0，并显示边界提示。
- `admin-ui/tests/components.test.ts`：`planningDisabled` 只禁用计划类动作，
  不阻断授权恢复。

## 修前失败 → 修后通过

修前命令（同一组新增回归，基线代码）：

```bash
npx vitest run tests/admin-state.test.ts tests/labels.test.ts tests/config-view.test.ts --reporter=verbose
```

结果：**7 failed / 16 passed，退出码 1**；失败项为 3 条任务归属、3 条安装文案、
1 条未保存草稿计划。原始日志 `.evidence/review-before.log`（不提交，随回复附件）。

修后：

```bash
npm run typecheck                    # 退出 0
npm test                             # 8 files, 48 passed / 0 failed / 0 skipped
npx vitest run tests/admin-state.test.ts tests/labels.test.ts tests/config-view.test.ts
                                     # 3 files, 25 passed
npm run build                        # 退出 0；JS 133.81 kB
npm run test:e2e                     # 1 passed，3.9s
```

- JUnit：`.evidence/vitest-junit.xml`（48 项，0 failures/0 errors/0 skipped）；
  `.evidence/playwright-junit.xml`（1 项，0 failures）。
- 新增回归全部进入现有 `npm test`；仓库现有 `admin-ui` CI job 已执行
  `npm ci` + `npm test` + build/typecheck，不新增 job。
- 修前/修后使用同一测试文件与断言，未跳过或放宽断言。

## 浏览器证据

`e2e/admin.spec.ts` 在真实生产构建 + 测试用同源外壳上运行：

- 真实 `bb-admin` 的登录/强制改密/旧密码与旧会话失效/刷新恢复/登出；
- 当前基线的真实 `GET /public-config`（200）与配置版本 v0 页面；
- 随后在浏览器路由层桩接 B 的 probe/plan/execution/SSE，验证取消无副作用、
  双击一次执行、UUID 幂等键、刷新恢复、409 失效，以及未保存草稿/旧版本任务的
  禁用与重新探测边界。

截图写入 `admin-ui/.evidence/screens/`（gitignore）。真实产品入口/SSE 的独立
证据由 `server/probes/public_browser.mjs` 负责；本目录的浏览器桩不计为端到端。
本轮未重跑该产品入口脚本。

## 未运行 / 限制

- 真实 Cloudflare/DNS/Tunnel、Arch 提权安装、Windows 真机/UAC/服务生命周期：
  NOT RUN；无本轮专用云权限与系统安装授权。
- 真实 Android/iOS/Windows 设备、真实移动浏览器：NOT RUN；只有 1440×900 与
  390×844 视口。
- 独立 QA 与固定候选 CI 结果：尚未开始/未收集；本文件是开发定向自测。
- 本分支不改服务端契约、锁文件、共享 CI 或集成分支；外部 NOT RUN 边界不变。
