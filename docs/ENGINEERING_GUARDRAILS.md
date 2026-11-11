# Cross-agent Engineering Guardrails

1. **Owner-gated delivery**：任何 Agent 不得自行 merge/push main、release/deploy production、修改生产数据、关闭父需求 Done。遵守分支保护；用户批准后才能操作。
2. **Minimal scope**：不新增与需求无关的框架、消息总线、微服务、功能或自动化。
3. **Evidence > claims**：每个测试必须附命令、退出码、关联 commit/环境；没运行写 NOT RUN；缺依赖写 BLOCKED。
4. **Contract first**：共享 REST、WebSocket、Actor/Message DTO 需 Orion 协调；开发者不能私改另一端的契约。
5. **One business truth**：SQLite/Backend 保有消息、动态、账户、事件权威状态；DSH Session 不等价聊天历史。
6. **Auth everywhere**：未认证/未授权请求必须拒绝；Account 与 Actor 区分；API/MCP 都必须验证主体与对象归属。
7. **Agent security**：开发 DSH Runtime 与产品 Bot DSH Runtime 隔离；不暴露通用 Shell、MCP 管理端点、DSH 控制口到公网；公网 API 有速率限制、体积限制、安全日志脱敏。
8. **Reproducibility**：Git checkout/分支固定，第三方 Skill 来源与版本记录；测试固定用例/字体/视口。
9. **No broad process kills**：禁止 `pkill -f`；使用 PID 清理自己启动的测试进程，不影响用户 Shell/桌面。
10. **No model fabrication**：模型 ID 来自实际运行时探测，不能把营销别名当作合法 provider/model 字符串。
11. **Skill precedence**：项目安全和 Owner 审批规则优先于第三方 Skills；尤其 ub-mode 中任何“push main at end”不适用。
12. **No impersonation of device testing**：Linux 桌面/golden/Widget 不表示 Android 实机通过。

### Definition of Ready
输入/输出清楚、范围边界、验收标准、跨端契约、明确 testability。

### Definition of Done
相同集成 commit 上完成实际可执行测试且附证据，未测风险透明，Owner 实际接受。
