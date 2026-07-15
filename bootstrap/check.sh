#!/usr/bin/env bash
# Verifies the repo is in a runnable, honest state:
#   - Node >= 22
#   - bridge/ typechecks and its test suite passes
#   - no .env file (or other obvious secret) is tracked by git
#   - a friendly, non-fatal note about iOS tooling (Xcode/XcodeGen), since
#     this environment may not have it and that's fine here
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }

echo "== Hermes Voice bootstrap check =="

# --- Node version ---
NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
if [ "$NODE_MAJOR" -lt 22 ]; then
  fail "Node 22+ required, found $(node --version)"
fi
ok "Node $(node --version)"

# --- Secrets hygiene ---
if git ls-files --error-unmatch bridge/.env >/dev/null 2>&1; then
  fail "bridge/.env is tracked by git — remove it and rotate any credentials in it"
fi
ok "no tracked .env file"

if git grep -nE '(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' -- . ':!package-lock.json' >/dev/null; then
  fail "tracked source contains a likely credential literal"
fi
ok "no obvious tracked credential literal"

# --- Backend install/typecheck/test ---
pushd bridge >/dev/null
if [ ! -d node_modules ]; then
  echo "Installing bridge/ dependencies..."
  npm install
fi
ok "bridge dependencies installed"

npm run typecheck
ok "bridge typechecks (tsc --noEmit, strict)"

npm test
ok "bridge test suite passes"
popd >/dev/null

# --- iOS tooling (best-effort, non-fatal) ---
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen found ($(xcodegen --version 2>/dev/null || echo unknown))"
else
  warn "xcodegen not found — required to generate HermesVoice.xcodeproj, macOS + Xcode only"
fi
if command -v swift >/dev/null 2>&1; then
  ok "swift found ($(swift --version 2>&1 | head -n1))"
else
  warn "swift toolchain not found — iOS source under ios/HermesVoice cannot be compiled or tested here, only read/edited. This is expected on Linux."
fi

echo
ok "bootstrap check complete"
