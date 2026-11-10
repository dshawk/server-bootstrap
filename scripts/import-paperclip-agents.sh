#!/usr/bin/env bash
# Import a paperclip-agents snapshot into a running Paperclip instance
# via the official CLI (`company import`). Secrets are not in the package;
# you must log into adapters / set env (e.g. GEMINI_API_KEY) afterwards.
#
# Usage:
#   scripts/import-paperclip-agents.sh [company-name] [--target new|existing] [-C company-id] [--dry-run]
# Default source: ../paperclip-agents/<company>/package
# Env: PAPERCLIP_API_BASE (http://127.0.0.1:3100), PAPERCLIPAI_VERSION, NEW_COMPANY_NAME
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_EXPORT="${PAPERCLIP_AGENTS_DIR:-$REPO_ROOT/paperclip-agents}"
API_BASE="${PAPERCLIP_API_BASE:-http://127.0.0.1:3100}"
PC_VERSION="${PAPERCLIPAI_VERSION:-2026.1023.0}"

COMPANY="${1:-}"
shift || true
TARGET="new"
COMPANY_ID=""
DRY="0"
YES="0"
INCLUDE="company,agents,skills"
COLLISION="rename"
NEW_NAME="${NEW_COMPANY_NAME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    -C|--company-id) COMPANY_ID="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    --include) INCLUDE="${2:-}"; shift 2 ;;
    --collision) COLLISION="${2:-}"; shift 2 ;;
    --new-company-name) NEW_NAME="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$COMPANY" ]; then
  echo "Usage: $0 <company-name> [--target new|existing] [-C company-id] [--dry-run] [--yes]" >&2
  if [ -d "$ROOT_EXPORT" ]; then
    echo "Available:" >&2
    find "$ROOT_EXPORT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '  %f\n' 2>/dev/null || ls "$ROOT_EXPORT"
  fi
  exit 1
fi

SRC="$ROOT_EXPORT/$COMPANY/package"
if [ ! -f "$SRC/.paperclip.yaml" ] && [ ! -f "$SRC/COMPANY.md" ]; then
  echo "No importable package at $SRC" >&2
  exit 1
fi

ARGS=(company import "$SRC" --include "$INCLUDE" --target "$TARGET" --collision "$COLLISION" --api-base "$API_BASE")
if [ "$TARGET" = "existing" ]; then
  if [ -z "$COMPANY_ID" ]; then
    echo "--target existing requires --company-id" >&2
    exit 1
  fi
  ARGS+=(--company-id "$COMPANY_ID")
fi
if [ -n "$NEW_NAME" ]; then
  ARGS+=(--new-company-name "$NEW_NAME")
fi
if [ "$DRY" = "1" ]; then
  ARGS+=(--dry-run)
fi
if [ "$YES" = "1" ]; then
  ARGS+=(--yes)
fi

echo "Importing $SRC -> target=$TARGET (api $API_BASE)"
npx --yes "paperclipai@${PC_VERSION}" "${ARGS[@]}"
echo "Import finished. Set secrets (GEMINI_API_KEY, cursor-agent login, kimi /login) on the new host."
echo "Then optionally run scripts/patch-paperclip-feedback-skills.sh and disable unused skills."
