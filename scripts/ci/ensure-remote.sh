#!/usr/bin/env bash
# 给当前 checkout 补上 origin（Multica 的任务工作树常常没有 remote），并验证推送凭据。
#
# 用法：bash scripts/ci/ensure-remote.sh [仓库 URL]
# 退出码：0 = origin 可用且 gh 凭据有效；1 = 有环节没通过（打印具体是哪一环）。
set -euo pipefail
URL="${1:-https://github.com/iiishop/BB}"
fail=0

if git remote get-url origin >/dev/null 2>&1; then
  echo "origin 已存在: $(git remote get-url origin)"
else
  git remote add origin "$URL"
  echo "已添加 origin -> $URL"
fi

if git fetch --no-tags --prune origin >/dev/null 2>&1; then
  echo "fetch: OK"
else
  echo "fetch: 失败（可能没网，或凭据无效）"; fail=1
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "gh 凭据: OK（$(gh api user --jq .login 2>/dev/null || echo unknown)）"
else
  echo "gh 凭据: 不可用，push 会被拒"; fail=1
fi

echo "当前分支: $(git branch --show-current)"
echo "提示：推分支用 git push -u origin <当前分支>；main 只由 Owner 合并，别直接推。"
exit "$fail"
