#!/usr/bin/env bash
# patch-surface.sh — report the downstream patch surface.
#
# Counts upstream-owned files changed on HEAD relative to a base ref
# (default: origin/upstream-main, falling back to upstream-main or upstream/main).
# Files under downstream-owned paths are excluded.
# New downstream areas must be added to OWNED_PREFIXES below.
#
#   ./scripts/patch-surface.sh
#   PATCH_SURFACE_BASE=upstream-main PATCH_SURFACE_WARN=12 PATCH_SURFACE_FAIL=50 ./scripts/patch-surface.sh
#
# Exit 0 when within budget, 0 with a WARNING when over the warn budget,
# 1 when over the fail budget.
set -euo pipefail

git fetch origin upstream-main --quiet 2>/dev/null || true

if [ -n "${PATCH_SURFACE_BASE:-}" ]; then
  BASE="${PATCH_SURFACE_BASE}"
elif git rev-parse --verify --quiet origin/upstream-main >/dev/null; then
  BASE="origin/upstream-main"
elif git rev-parse --verify --quiet upstream-main >/dev/null; then
  BASE="upstream-main"
elif git rev-parse --verify --quiet upstream/main >/dev/null; then
  BASE="upstream/main"
else
  echo "FAIL: could not resolve upstream mirror ref (expected origin/upstream-main, upstream-main, or upstream/main)"
  exit 1
fi

WARN="${PATCH_SURFACE_WARN:-12}"
FAIL="${PATCH_SURFACE_FAIL:-50}"

OWNED_PREFIXES=(
  "src/constellation/"
  "src/constellation_tests.zig"
  "tests/e2e/constellation-harness.test.ts"
  "tests/e2e/cxn-console.test.ts"
  "docs/"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/workflows/upstream-sync.yml"
  ".github/workflows/patch-surface.yml"
  "scripts/patch-surface.sh"
)

upstream=()
downstream=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  owned=0
  for prefix in "${OWNED_PREFIXES[@]}"; do
    if [[ "$path" == "$prefix"* ]]; then
      owned=1
      break
    fi
  done
  if (( owned )); then
    downstream+=("$path")
  else
    upstream+=("$path")
  fi
done < <({ git diff --name-only "${BASE}...HEAD" -- || true; git status --porcelain --untracked-files=all -- . | awk '$1 == "!!" { next } { sub(/^[A-Z? ]{1,2} +/, ""); gsub(/^"|"$/, ""); sub(/.* -> /, ""); print }' || true; } | sort -u)

echo "patch-surface vs ${BASE}: ${#upstream[@]} upstream-owned, ${#downstream[@]} downstream-owned"
if (( ${#upstream[@]} )); then
  echo "--- upstream-owned ---"
  printf '%s\n' "${upstream[@]}"
fi
if (( ${#downstream[@]} )); then
  echo "--- downstream-owned ---"
  printf '%s\n' "${downstream[@]}"
fi

if (( ${#upstream[@]} > FAIL )); then
  echo "FAIL: upstream-owned patch surface ${#upstream[@]} exceeds budget ${FAIL}"
  exit 1
fi
if (( ${#upstream[@]} > WARN )); then
  echo "WARNING: upstream-owned patch surface ${#upstream[@]} exceeds warn threshold ${WARN}"
fi
echo "OK"
