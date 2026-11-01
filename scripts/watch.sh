#!/usr/bin/env bash
# Следить за локальными коммитами и запускать CI/CD без GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
git rev-parse --show-toplevel > /dev/null
LAST=""
echo "Ожидание локальных коммитов. Остановка: Ctrl+C"
while true; do
  CURRENT="$(git rev-parse HEAD)"
  if [[ "$CURRENT" != "$LAST" && -z "$(git status --porcelain)" ]]; then
    LAST="$CURRENT"
    if ./scripts/deploy.sh; then echo "$CURRENT" > .pipeline-commit; fi
  fi
  sleep 5
done
