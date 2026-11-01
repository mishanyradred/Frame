#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker > /dev/null 2>&1; then
  echo "Установите Docker Desktop перед запуском Frame." >&2
  exit 1
fi

if ! docker info > /dev/null 2>&1; then
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "Запустите Docker и повторите запуск Frame." >&2
    exit 1
  fi
  echo "Запускаю Docker Desktop…"
  open -a Docker
  for _ in $(seq 1 60); do
    docker info > /dev/null 2>&1 && break
    sleep 2
  done
  if ! docker info > /dev/null 2>&1; then
    echo "Docker не стал готов за две минуты. Проверьте окно Docker Desktop." >&2
    exit 1
  fi
fi

./scripts/deploy.sh
