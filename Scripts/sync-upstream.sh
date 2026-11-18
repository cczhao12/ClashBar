#!/usr/bin/env bash
set -euo pipefail

# 把 patched 分支 rebase 到上游的新 tag 上。
#
#   ./Scripts/sync-upstream.sh v0.4.0
#
# 不带参数时只打印当前状态，不做任何改动。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET_TAG="${1:-}"

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "缺少 upstream remote，先执行：git remote add upstream https://github.com/Sitoi/ClashBar.git" >&2
  exit 1
fi

git fetch upstream --tags --force

if [[ -z "$TARGET_TAG" ]]; then
  echo "远端 tag（最近的 10 个）："
  git tag --sort=-v:refname | head -10
  echo
  echo "当前分支：$(git rev-parse --abbrev-ref HEAD)"
  echo "patched 的基线：$(git merge-base --octopus main patched 2>/dev/null | head -1)"
  echo "用法：$0 <新 tag>"
  exit 0
fi

git rev-parse -q --verify "refs/tags/${TARGET_TAG}" >/dev/null || {
  echo "找不到 tag：${TARGET_TAG}" >&2
  exit 1
}

OLD_BASE="$(git merge-base main patched)"
echo "旧基线：$(git describe --tags --always "$OLD_BASE")"
echo "新基线：${TARGET_TAG}"

if [[ "${OLD_BASE}" == "$(git rev-parse "${TARGET_TAG}^{commit}")" ]]; then
  echo "已经在 ${TARGET_TAG} 上，无需同步。"
  exit 0
fi

# main 始终等于上游最新 tag，避免两处"基线"漂移。
git branch -f main "${TARGET_TAG}"
git rebase --onto "${TARGET_TAG}" "${OLD_BASE}" patched

echo
echo "完成。冲突时的处理顺序：git status -> 改文件 -> git add -> git rebase --continue"
echo "改完记得跑一次构建再打 tag。"
