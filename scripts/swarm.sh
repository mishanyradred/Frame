#!/usr/bin/env bash
# Учебный одноузловой Swarm. Образы локальные: реестр не требуется.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != active ]]; then docker swarm init; fi
docker compose build
docker volume create frame_files-data > /dev/null
# Первый старт создаёт тома с правильными правами и инициализирует БД.
if ! docker stack ls --format '{{.Name}}' | grep -qx frame; then
  docker compose up -d --wait --wait-timeout 180
  docker compose down
fi
docker stack deploy --resolve-image never --detach=true -c docker-stack.yml frame
./scripts/wait-stack.sh frame
./scripts/smoke-test.sh
echo "Swarm Frame: http://localhost:${HTTP_PORT:-8080}"
