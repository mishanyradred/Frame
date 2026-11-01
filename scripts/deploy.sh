#!/usr/bin/env bash
# Локальный CI/CD: проверка конфигурации → сборка → проверка Python → запуск → сквозной тест.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == active ]] && docker stack ls --format '{{.Name}}' | grep -qx frame; then
  echo "Сначала остановите учебный Swarm: ./scripts/teardown.sh" >&2
  exit 1
fi

echo "[1/5] Проверка конфигураций"
docker compose config --quiet
docker stack config -c docker-stack.yml > /dev/null
for script in scripts/*.sh; do bash -n "$script"; done

echo "[2/5] Сборка пяти образов"
docker compose build
docker volume create frame_files-data > /dev/null

echo "[3/5] Проверка Python"
docker compose run --rm --no-deps --entrypoint python backend -c "from pathlib import Path; compile(Path('app/main.py').read_text(), 'main.py', 'exec')"
docker compose run --rm --no-deps --entrypoint python transcoder -c "from pathlib import Path; compile(Path('worker.py').read_text(), 'worker.py', 'exec')"

echo "[4/5] Запуск"
docker compose up -d --wait --wait-timeout 180

echo "[5/5] Сквозной тест"
./scripts/smoke-test.sh
echo "Frame: http://localhost:${HTTP_PORT:-8080}"
