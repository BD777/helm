#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECRET_PATTERN='BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{32,}'
INTERNAL_PATTERN='ByteDance|bytedance|byted|feishu|Feishu|lark|Lark'

COMMON_PATHSPECS=(
  .
  ':(exclude)build/**'
  ':(exclude)DerivedData/**'
  ':(exclude)*.jpg'
  ':(exclude)*.jpeg'
  ':(exclude)*.png'
  ':(exclude)*.xcuserstate'
  ':(exclude)scripts/open-source-scan.sh'
)

echo "Scanning current tree for high-risk secret patterns..."
if git grep -n -I -E "$SECRET_PATTERN" -- "${COMMON_PATHSPECS[@]}"; then
  echo "High-risk secret-like content found in the current tree." >&2
  exit 1
fi

echo "Scanning current tree for internal-only terms..."
if git grep -n -I -E "$INTERNAL_PATTERN" -- "${COMMON_PATHSPECS[@]}"; then
  echo "Internal-only term matches found. Review the output above before publishing." >&2
  exit 1
fi

echo "Scanning git history for high-risk secret patterns..."
if git grep -n -I -E "$SECRET_PATTERN" $(git rev-list --all) -- "${COMMON_PATHSPECS[@]}"; then
  echo "High-risk secret-like content found in git history." >&2
  exit 1
fi

echo "Open source scan passed."
