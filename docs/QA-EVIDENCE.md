# Sentinel QA evidence（本地、按需）

这是小型标准库检查器，不是通用 QA 平台，也不是模型裁判。普通 PR **不需要**提交模型报告；现有 CI `plan` 的 `unittest discover` 自动跑检查器正负自测，不增加 job。产品验收时，reviewer 根据实际需求指定必要规则，再运行报告检查。

## 收集：实际命令，而不是自己填写 exit_code

从仓库根目录执行，先提交测试与候选代码，确保 worktree 干净。产物放仓库外或已忽略目录。示例（`/tmp/bb-qa-unit` 和 XML 必须尚不存在）：

```bash
uv run --no-project python scripts/ci/qa_evidence.py run \
  --cwd "$PWD/admin-ui" --out /tmp/bb-qa-unit \
  --junit /tmp/bb-qa-unit.xml -- \
  npm test -- --reporter=junit --outputFile=/tmp/bb-qa-unit.xml
```

`run` 不通过 shell 执行命令；记录真实 argv、cwd、Git HEAD、起跑 dirty 状态、结束时 `after_sha`/`tracked_after` 跟踪状态与一致性标记、进程退出码。保留 `output.log`、复制的新鲜 `junit.xml`、写入两文件 SHA-256 的 `run.json`。退出码透传；无 XML 的环境错误仍保留日志/receipt，但不能通过检查。已有 XML 或输出目录会被拒绝，避免拿上次的绿报告顶替。命令本身由用户选择并信任；不要把未审阅报告中的命令自动执行。

## 报告格式

以下是格式模板（占位 SHA 必须替换，不是一次真实 PASS）。报告路径相对于文件自身解析。可把一次 runner 产物关联到多条规则，不复制摘要当证据。

```json
{
  "candidate_sha": "<完整40位候选SHA>",
  "rules": [{
    "id": "task-authority",
    "rule": "迟到的 current GET 不得覆盖新 probe 任务",
    "entry": "ConfigView 刷新 → admin-state.loadCurrentTask / startProbe",
    "status": "tested",
    "run": "bb-qa-unit/run.json",
    "testcase": {
      "classname": "<复制JUnit的classname>",
      "name": "<复制JUnit的name>"
    },
    "before": {
      "sha": "<完整40位修前SHA>",
      "run": "bb-qa-before/run.json",
      "assertion": "<目标断言失败文本的稳定片段>"
    },
    "evidence": [{
      "path": "screenshots/configuration.png",
      "sha256": "<该文件的sha256>"
    }]
  }]
}
```

- `candidate_sha` 必须同时等于 reviewer 的 `--candidate` 和 runner HEAD；dirty 或执行中修改跟踪源码的记录被拒绝。
- `rule` 说明可观察规则，`entry` 说明真实产品入口；不是只测试自己写的复制实现。检查器能验证对应 testcase 的存在，**不能自动判断测试是否真的覆盖产品入口**，这仍需代码评审。
- 自动测试数从 JUnit `<testcase>` 实数；失败、错误、skip 从节点读取并核对叶 suite 的计数，不相信 JSON 中的 `passed: true` 或自填 totals。零收集、零实际执行、必要规则对应 testcase 被 skip、runner 非零退出或任一 failure/error 均不能当候选 PASS。无关平台 skip 只统计报告，不自行扩张验收范围；tests 是收集总数，实际执行数为 tests − skipped。支持 UTF-8 pytest/Vitest/Node JUnit 与 Flutter 原生 JSON reporter；拒绝 DTD/entity、未知结构和截断事件流。
- 受信 reviewer 用 `--require-regression ID` 指定声称“修复了缺陷”的规则，检查器对这些 ID 强制要求 `before`，不能由报告作者删掉。普通验收可省略；即使没有此参数，已提供的 before 也必须有效。修前/修后应运行同一 probe，reviewer 核对差异；检查器要求同一 classname/name，修前不同 SHA、非零退出、目标规范化失败类别必须为 assertion 且含指定断言片段（原始类型保留，映射规则见下节）。缺依赖、导入失败、`<error>`、无收集、别处断言失败不算反例。不能拿目前的红 probe 声称已完成修复。
- `evidence` 可省略，适合附加截图/trace；给出则读取文件核对 SHA-256。但哈希只证明字节一致，**不证明截图里的行为**。自动 runner 日志/XML 的哈希始终必查。
- 未测必要项使用 `status: "not_run"`（或 `blocked`）并说明阻塞原因；检查器拒绝所有非 `tested` 项。无法产出支持的 runner 证据的人工验收暂不被此脚本认证，不用虚构 testcase 换绿灯。

```bash
# 必要项来自 reviewer 的验收清单，而不是让报告作者自行缩减。
uv run --no-project python scripts/ci/qa_evidence.py check /tmp/report.json \
  --candidate "$(git rev-parse HEAD)" \
  --require task-authority --require config-authority \
  --require-regression task-authority

# 自测，与既有 plan job 同一 discover 入口；无需产品依赖：
uv run --no-project python -m unittest discover -s scripts/ci -p 'test_*.py' -v
```

`check` 成功退出 0，保留原 JSON 数组形状，并输出 SHA、argv、退出码、目标 testcase、真实 tests/failures/errors/skipped/executed、before 失败类别/原类型、缺口与证据路径；不灌入长堆栈。拒绝退出 2，stdout 输出 `{status: "rejected", candidate_sha, gaps, evidence_paths}`，stderr 保留原因。漏写 `--require` 或报告遗漏必要 ID 都不能通过。必要性本身由人/上游验收规格决定，这个脚本不理解全部产品需求。

## 原生 runner 适配与复现

工具入口仍是本仓库 `scripts/ci/qa_evidence.py`，内部 `qa_results.py` 将不同格式转换为同一不可变 Case 模型；计数、目标匹配、SHA/hash/skip/回归判定只有一份。无需全局安装或平台 skill 配置。用新分支工具检查旧干净 worktree 时，可用脚本绝对路径，`--cwd` 指向实际被测源码；不要把工具分支 SHA 当作被测产品 SHA。

- **Node `node:test` JUnit**：`testCodeFailure` 是异常包装，不等于断言。仅原始 failure 正文中的直接 `cause: AssertionError [ERR_ASSERTION]:` 映射为 assertion；TypeError 等运行错误、无法识别的 cause 都不能认证回归。原 XML `type` 不改写。
- **pytest JUnit**：原生 `pytest tests` 根标识且没有 failure.type 时，以 traceback **最后的 `file:line: ExceptionType`** 判定；AssertionError 才是断言，TypeError/导入/收集错误不算。缺少该结构（例如自定义 `--tb` 输出）保守拒绝，不凭 message 出现 `assert` 猜测。
- **Flutter `--reporter=json`**：直接收集 stdout JSONL，不转 JUnit。仅协议 0.1.1；error.isFailure=true 对应断言、false 对应环境/运行错误；与 testDone、最终 done.success 互相校验。必须有 start/allSuites/每个 testStart 对应的 testDone/最终 done；重复、未知、截断均拒绝。隐藏的成功 loading 事件不计作产品测试；隐藏失败不能被忽略。`classname` 是 suite.path 相对 receipt.cwd 的路径（例如 `test/foo_test.dart`），`name` 原样使用 test.name；同名歧义仍拒绝。

```bash
# Node：--junit 路径必须与 runner 输出路径相同且尚不存在。
python scripts/ci/qa_evidence.py run --cwd "$PWD" --out /tmp/node-evidence \
  --junit /tmp/node-evidence.xml -- \
  node --test --test-reporter=junit --test-reporter-destination=/tmp/node-evidence.xml test/probe.cjs

# pytest：无需补写 failure.type。
python scripts/ci/qa_evidence.py run --cwd "$PWD" --out /tmp/pytest-evidence \
  --junit /tmp/pytest-evidence.xml -- pytest --junitxml=/tmp/pytest-evidence.xml tests/test_probe.py

# Flutter：不要 2>&1 混入编译 stderr，也不要删除非 JSON 行来换绿灯。
python scripts/ci/qa_evidence.py run --cwd "$PWD" --out /tmp/flutter-evidence \
  --flutter-json -- flutter test --reporter=json test/probe_test.dart
```

Flutter 模式保留原始 `flutter.jsonl`（stdout）和 `output.log`（stderr），两者 hash 均在 receipt；JUnit 模式保持原行为。旧 receipt 无 format 时按 junit 读取。未知 format 不回退。任意 testcase 的未知/运行失败都会拒绝整份证据，不会因为另一个目标断言失败而放行。失败原始日志永不改写；摘要不是原始证据的替代品。只有一个 skip 的运行不能 PASS，无关 skip 在摘要 gaps 中报告。

`fixtures/qa_native/`（相对 `scripts/ci`）包含 Node、pytest、Flutter 各自真实 pass/assertion/runtime/skip/compile 共 15 次执行的源码、原始报告、stdout/stderr 和 `provenance.json`（版本/argv/退出码）。损坏/未知负例仅在测试内由这些夹具变异，**不冒充 runner 实测产物**。默认 CI 回放不要求安装这三个 runner。可选重跑（需本机已有 Node/pytest/Flutter，Flutter pub get 可能访问依赖网络）：

```bash
# 原地重生成夹具；时间、PID、临时路径变化是预期，禁止“规范化”原始错误类型。
FLUTTER=/path/to/flutter python scripts/ci/fixtures/qa_native/generate.py
# 真实命令 -> capture -> 原始 receipt -> check；输出目录必须是新的。
FLUTTER=/path/to/flutter python scripts/ci/fixtures/qa_native/live_smoke.py /tmp/qa-live-new
```

这些是**证据工具**的兼容性测试，不代表 BB 产品验收完成，也不能消除真实 Windows/GUI/外部环境未测的独立缺口。

## PR13 时序回归与 review-only probes

来源：独立审计 `independent-hema.test.ts` 的实际 store 调用与可控 deferred Promise，非复制 store 实现。为避免把六个失败样例误报成六个缺陷，只保留两个已确认 P2 的参数化最小 probe。

| 入口 | 范围 | 基线 600c7af 的预期 |
| --- | --- | --- |
| `cd admin-ui && npm test` | 参数化已有 `tests/admin-state.test.ts`：迟到 GET 对 execution/probe；旧 SSE 对非终态/终态，并检查旧状态回调 | 50 个通过（原 48 保留覆盖，新增两种有意义路径） |
| `cd admin-ui && npm run test:review-probes` | `review-probes/authority.test.ts`：GET/PUT 两种乱序；authorize 两组旧任务 seq | 4 个目标断言失败，对应 **2 个 P2** |

review 配置明确替换 include，只收集 review-probes；普通 vitest 配置仍只收集 `tests/**/*.test.ts`。没有 skip/xfail、没有改产品、没有把已知红测塞进默认 CI。

- 配置 P2：晚到 GET 把 v4 回滚到 v3，或晚到 PUT 把 v5 回滚到 v4（复用已有 FakeApi 的初始 v3）。
- authorize P2：晚到旧任务授权响应替换 NEW 任务，并关闭 NEW SSE。
- 当前 review-only **不是永久 CI 防回归**。修复以后把相应 probe 移入 `tests/`，保存修前目标断言失败与修后通过的证据对，再让默认 CI 承担防回归。
- 原审计中的 logout 与 UI 可达性案例没有在这里扩展为更多缺陷，也未宣称被本轮重测覆盖。UI 可达性和浏览器验证需要独立证据；store probe 不等于浏览器验收。

## 信任与成本边界

此工具防止常见的空跑、漏测、旧文件、计数虚报、把环境错误当修前反例，不是防恶意作者的远程证明：有权限改 receipt、XML 和哈希的人仍能合谋造假。需要强可信时由 reviewer 在受控干净 worktree 重新执行 `run`，保存 CI 原始 artifact/commit 身份；不能把签名/远程执行平台塞进这个小脚本。执行后新增的无关 untracked 不作为跟踪源码变化；产物建议外置。执行前已有 untracked 则视为 dirty。前后快照不能侦测中途修改后又还原的恶意行为，也不监控 ignored 文件；依赖版本与外部服务状态不由 Git HEAD 完整证明；依赖必须锁定安装，实际入口、覆盖充分性、必要项清单、截图含义仍需人审。

默认自测只运行临时 Git 仓库和 Python 子进程，并回放已提交的真实 runner 夹具；无模型/API 调用。可选真实 runner 重生成与端到端命令见上节。Vue probes 使用本地 mock API/受控 Promise，无真实 token 或云端副作用。测试初始化开销主要是依赖安装；不重启 agent、不部署产品。
