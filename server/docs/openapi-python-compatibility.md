## OpenAPI 快照与 Python 版本

选择在 `tests/test_profile_contract.py` **完整快照比较之前归一化**，不改变生产 API，也不删除快照断言。

FastAPI 的默认 422 description 来自运行时的 HTTP 状态短语；Python 3.12 使用 `Unprocessable Entity`，3.13 使用 `Unprocessable Content`。此外，实际 3.12 运行还发现 413 的 `Request Entity Too Large` 在 3.13 为 `Content Too Large`。逐字段 diff 仅发现这两类状态描述差异，并非本项目的数据模型或鉴权契约变化。首次仅处理 422 的运行保留为 14 passed / 1 failed，不记通过。

归一化仅遍历 paths 中各操作的 `responses["422"]["description"]` 与 `responses["413"]["description"]`，分别将上述两个已知旧短语映射为快照中的新短语，对实际 schema 与快照做相同处理。未知描述不归一化；其他状态、字段、响应模型、required、security、additionalProperties 等全部继续完整比较。原有逐接口安全断言保留；新增保护测试确认自定义 422/413 描述、其他状态码描述及 response content 都不能被归一化掉。

这样导出器仍忠实记录运行时 OpenAPI，不需要在生产生成链路加入测试兼容逻辑。仓库快照保留 3.13 导出文本；3.12 与 3.13 都能严格验证同一接口契约。后续有新的短语变化应显式评审，不能忽略所有 description。

从 `server/` 执行（两个独立 venv 防止同时测试互相覆盖）：

```bash
UV_PROJECT_ENVIRONMENT=../../handoff/ci-python312 uv sync --frozen --python 3.12
UV_PROJECT_ENVIRONMENT=../../handoff/ci-python312 uv run --frozen --python 3.12 pytest tests/test_profile_contract.py -q
UV_PROJECT_ENVIRONMENT=../../handoff/ci-python313 uv sync --frozen --python 3.13
UV_PROJECT_ENVIRONMENT=../../handoff/ci-python313 uv run --frozen --python 3.13 pytest tests/test_profile_contract.py -q
uv run ruff check src tests
```

日志、两个解释器的实际版本和退出码随本轮交接提供。环境路径可以替换为自己独立的工作目录；不需要修改系统 Python、依赖锁或 CI 的 Python pin。
