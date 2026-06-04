#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required for the open source scan." >&2
  exit 1
fi

SECRET_PATTERN='BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{32,}'
INTERNAL_PATTERN='ByteDance|bytedance|byted|feishu|Feishu|lark|Lark'

COMMON_EXCLUDES=(
  --glob '!build/**'
  --glob '!DerivedData/**'
  --glob '!.git/**'
  --glob '!*.jpg'
  --glob '!*.jpeg'
  --glob '!*.png'
  --glob '!*.xcuserstate'
  --glob '!scripts/open-source-scan.sh'
)

echo "Scanning current tree for high-risk secret patterns..."
if rg -n -I --hidden "${COMMON_EXCLUDES[@]}" -e "$SECRET_PATTERN" .; then
  echo "High-risk secret-like content found in the current tree." >&2
  exit 1
fi

echo "Scanning current tree for internal-only terms..."
if rg -n -I --hidden "${COMMON_EXCLUDES[@]}" -e "$INTERNAL_PATTERN" .; then
  echo "Internal-only term matches found. Review the output above before publishing." >&2
  exit 1
fi

echo "Scanning git history for high-risk secret patterns..."
if git grep -n -I -E "$SECRET_PATTERN" $(git rev-list --all) -- \
  ':(exclude)build/**' \
  ':(exclude)DerivedData/**' \
  ':(exclude)*.jpg' \
  ':(exclude)*.jpeg' \
  ':(exclude)*.png' \
  ':(exclude)*.xcuserstate' \
  ':(exclude)scripts/open-source-scan.sh'; then
  echo "High-risk secret-like content found in git history." >&2
  exit 1
fi

echo "Open source scan passed."
