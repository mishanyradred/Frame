#!/usr/bin/env bash
# Удалить учебный стек. Данные в томах сохраняются.
set -euo pipefail
docker stack rm frame
for _ in $(seq 1 90); do
  if [[ -z "$(docker ps -q --filter label=com.docker.stack.namespace=frame)" ]]; then exit 0; fi
  sleep 2
done
echo "Контейнеры Swarm ещё останавливаются" >&2
exit 1
