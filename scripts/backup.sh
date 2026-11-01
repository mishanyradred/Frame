#!/usr/bin/env bash
# Согласованная копия БД и общего файлового тома в режиме Compose.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == active ]] && docker stack ls --format '{{.Name}}' | grep -qx frame; then
  echo "Для резервной копии переключитесь из Swarm в Compose" >&2; exit 1
fi
DEST="$PWD/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
# При неудаче не оставляем сервисы остановленными.
trap 'docker compose up -d --wait --wait-timeout 120' EXIT
docker compose stop proxy backend transcoder
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$DEST/db.dump"
docker run --rm --user "$(id -u):$(id -g)" --entrypoint tar \
  --mount type=volume,src=frame_files-data,dst=/data,readonly \
  --mount "type=bind,src=$DEST,dst=/backup" \
  frame-transcoder:local -czf /backup/files.tar.gz -C /data .
touch "$DEST/COMPLETE"
echo "Копия: $DEST"
