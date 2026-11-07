#!/usr/bin/env bash
# 本地 SwiftLint 检查，行为与 .github/workflows/lint.yml 一致。
#
#   bash scripts/lint.sh            只检查
#   bash scripts/lint.sh --fix      自动修复可修复项后不再检查
#   bash scripts/lint.sh --strict   warning 也视为失败
#   bash scripts/lint.sh -h         显示帮助
set -euo pipefail

cd "$(dirname "$0")/.."

FIX=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg（可用：--fix / --strict / -h）" >&2; exit 2 ;;
  esac
done

if command -v swiftlint >/dev/null 2>&1; then
  RUNNER=(swiftlint)
elif command -v docker >/dev/null 2>&1; then
  # 本机没有 SwiftLint 时退回官方镜像；工作目录读写挂载，--fix 才能落盘。
  RUNNER=(docker run --rm -v "$PWD:/work" -w /work ghcr.io/realm/swiftlint:latest)
else
  echo "未找到 swiftlint，也没有 docker。" >&2
  echo "macOS 安装：brew install swiftlint" >&2
  exit 1
fi

BASELINE_ARG=""
if [ -f .swiftlint-baseline.json ]; then
  BASELINE_ARG="--baseline .swiftlint-baseline.json"
  echo "使用基线 .swiftlint-baseline.json，只报告新增问题"
fi

if [ "$FIX" -eq 1 ]; then
  echo "== 自动修复 =="
  "${RUNNER[@]}" --fix --quiet --force-exclude
  echo "完成，请检查改动后用 git diff 复核。"
  exit 0
fi

# 只拼接非空参数：空数组在 bash 3.2（macOS 默认）配合 set -u 展开会报错。
ARGS=(lint --quiet --force-exclude --reporter emoji)
if [ -n "$BASELINE_ARG" ]; then
  # shellcheck disable=SC2206
  ARGS+=($BASELINE_ARG)
fi
if [ "$STRICT" -eq 1 ]; then
  ARGS+=(--strict)
  echo "收紧模式：warning 也视为失败"
fi

"${RUNNER[@]}" "${ARGS[@]}"
