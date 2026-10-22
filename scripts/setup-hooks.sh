#!/usr/bin/env bash
# Installs the git pre-push hook
set -euo pipefail

cp hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
echo "✅ Pre-push hook installed"
echo "   AI audit will run automatically before every git push"
