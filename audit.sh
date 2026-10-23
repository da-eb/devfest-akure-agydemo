#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Safe Deployments Lab — Local Audit Script
# ══════════════════════════════════════════════════════════════════════════════
# Runs Antigravity CLI (agy) against the codebase using AGENTS.md as the rules.
# Exits 1 on any critical finding, so the pre-push hook blocks the push.
#
# Usage:
#   ./audit.sh                  # Step 1: code audit
#   ./audit.sh --save           # Step 1, and save the report to audit-report.md
#   ./audit.sh --pre-push       # Used by the git pre-push hook (fails closed)
#   ./audit.sh --deps           # Step 1, then Step 2: dependency advisories
#
# Prerequisites:
#   curl -fsSL https://antigravity.google/cli/install.sh | bash
#   agy                         # run once, interactively, to sign in
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

REPORT_FILE="audit-report.md"
SAVE_REPORT=false
PRE_PUSH=false
RUN_DEPS=false

for arg in "$@"; do
  case $arg in
    --save)      SAVE_REPORT=true ;;
    --pre-push)  PRE_PUSH=true; SAVE_REPORT=true ;;
    --deps)      RUN_DEPS=true ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    *)           echo "Unknown option: $arg"; exit 2 ;;
  esac
done

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

block() {
  echo -e "${RED}${BOLD}Push blocked.${NC} $1"
  if [ "$PRE_PUSH" = true ]; then
    echo -e "${DIM}To bypass (not recommended): git push --no-verify${NC}"
  fi
  exit 1
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v agy &> /dev/null; then
  echo -e "${RED}❌ Antigravity CLI (agy) not found.${NC}"
  echo ""
  echo "Install it:"
  echo "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
  echo ""
  echo "Then run 'agy' once on its own to sign in through the browser."
  exit 1
fi

if [ ! -f "AGENTS.md" ]; then
  echo -e "${RED}❌ AGENTS.md not found.${NC}"
  echo "Run this script from the root of the lab repo."
  exit 1
fi

# ── Step 1: code audit ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Safe Deployments Lab — AI Audit Gate${NC}"
echo -e "${DIM}Antigravity CLI · step 1: code audit${NC}"
echo ""
echo -e "${BLUE}→ Reading AGENTS.md rules...${NC}"
echo -e "${BLUE}→ Scanning app/ + .github/workflows/ + config files...${NC}"
echo ""

# ── Build the prompt ──────────────────────────────────────────────────────────
# The files to audit go straight into the prompt, so agy never needs to run a
# shell command (ls, cat, grep). Headless mode can't ask you to approve those,
# so it auto-denies them and the audit would come back empty.
# AGENTS.md is still loaded automatically because we run from the repo root.

# Every file in the repo, so the audit can spot a committed .env or key file.
if git rev-parse --is-inside-work-tree &> /dev/null; then
  FILE_LIST=$(git ls-files)
else
  FILE_LIST=$(find . -type f -not -path './.git/*' | sed 's|^\./||' | sort)
fi

PROMPT="Run the audit defined in AGENTS.md on the files below.
Every file you need is included in this message. Do not call any tools and do
not run any commands. Read the contents below and write the report.

=== Files tracked in this repo ===
${FILE_LIST}
"

for f in app/* app/.env.example .github/workflows/*; do
  [ -f "$f" ] || continue
  # Skip anything large or binary; the audit only needs source and config.
  [ "$(wc -c < "$f")" -gt 100000 ] && continue
  grep -Iq . "$f" 2>/dev/null || continue
  PROMPT+="
=== FILE: $f ===
$(cat -n "$f")
"
done

AUDIT_OUTPUT=$(agy -p "$PROMPT" 2>&1)
AGY_STATUS=$?

echo "$AUDIT_OUTPUT"
echo ""

if [ "$SAVE_REPORT" = true ]; then
  echo "$AUDIT_OUTPUT" > "$REPORT_FILE"
  echo -e "${DIM}Report saved: $REPORT_FILE${NC}"
  echo ""
fi

# If agy itself failed (not signed in, no network), we can't vouch for the code.
if [ $AGY_STATUS -ne 0 ]; then
  echo -e "${RED}agy exited with status $AGY_STATUS.${NC}"
  echo -e "${DIM}If it says authentication required, run 'agy' once interactively to sign in.${NC}"
  block "The audit did not run, so the push can't be cleared."
fi

# Headless mode soft-denies tools it can't prompt for and still exits 0.
if echo "$AUDIT_OUTPUT" | grep -qi "cannot prompt\|auto-denied"; then
  echo -e "${YELLOW}agy tried to use a tool that headless mode can't approve.${NC}"
  echo -e "${DIM}The files are already in the prompt, so re-run ./audit.sh. Don't use --dangerously-skip-permissions.${NC}"
  block "The audit did not finish, so the push can't be cleared."
fi

# ── Gate ──────────────────────────────────────────────────────────────────────
# Read the SUMMARY line's critical count. AGENTS.md tells agy to always print it.
CRITICALS=$(echo "$AUDIT_OUTPUT" | grep -oE 'Critical:[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+')

if [ -z "$CRITICALS" ]; then
  # No summary line means we can't tell. Fail closed: don't let it through.
  echo -e "${YELLOW}Could not find the SUMMARY line in the audit output.${NC}"
  block "Verdict unknown. Re-run ./audit.sh and check the report."
fi

if [ "$CRITICALS" -gt 0 ]; then
  block "$CRITICALS critical finding(s). Fix them and push again."
fi

echo -e "${GREEN}${BOLD}No critical findings.${NC} Safe to push."
echo ""

# ── Step 2 (optional): dependency advisories ─────────────────────────────────
# Opt-in only. The pre-push hook never runs this, so a push can't hang on it.
if [ "$RUN_DEPS" = true ]; then
  echo -e "${DIM}Step 2: dependency advisories${NC}"
  DEPS_FILE="deps-audit.json"

  if [ -f package.json ]; then
    npm audit --json > "$DEPS_FILE" 2>/dev/null || true
  elif [ -f app/requirements.txt ]; then
    if ! command -v pip-audit &> /dev/null; then
      echo "pip-audit not found. Install it: pip install pip-audit"
      exit 0
    fi
    pip-audit -r app/requirements.txt -f json > "$DEPS_FILE" 2>/dev/null || true
  else
    echo "No package.json or app/requirements.txt found. Skipping."
    exit 0
  fi

  if [ ! -s "$DEPS_FILE" ]; then
    echo -e "${YELLOW}The advisory scan returned nothing (no network?). Skipping.${NC}"
    exit 0
  fi

  echo -e "${BLUE}→ Advisories saved to $DEPS_FILE. Asking agy which ones the app reaches...${NC}"
  echo ""
  DEPS_PROMPT="Below is a dependency advisory scan and the app source. Do not call any tools.
For each advisory, say whether this app actually calls the vulnerable code: REACHABLE or
NOT REACHABLE, with the file and line that proves it. Then say which to upgrade first.

=== $DEPS_FILE ===
$(cat "$DEPS_FILE")
"
  for f in app/*.py app/*.js app/*.ts; do
    [ -f "$f" ] && DEPS_PROMPT+="
=== FILE: $f ===
$(cat -n "$f")
"
  done
  agy -p "$DEPS_PROMPT" || true
  echo ""
  echo -e "${DIM}Step 2 is advisory only. It does not block the push.${NC}"
fi

exit 0
