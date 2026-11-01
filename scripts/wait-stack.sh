#!/usr/bin/env bash
# Ограниченное ожидание всех реплик. При сбое выводит причины отклонения задач.
set -euo pipefail
STACK="${1:-frame}"
DEADLINE=$((SECONDS + ${STACK_TIMEOUT:-240}))

while ((SECONDS < DEADLINE)); do
  REPLICAS="$(docker stack services "$STACK" --format '{{.Replicas}}')"
  SERVICES="$(docker stack services "$STACK" --format '{{.Name}}')"
  # Имена сервисов не содержат пробелов; передаются отдельными аргументами inspect.
  UPDATES="$(docker service inspect $SERVICES --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')"
  if grep -Eq 'paused|rollback' <<< "$UPDATES"; then
    docker stack ps "$STACK" --no-trunc
    echo "Обновление остановлено или откачено" >&2
    exit 1
  fi
  if [[ -n "$REPLICAS" ]] && ! grep -q updating <<< "$UPDATES" && awk -F/ '$1 != $2 {exit 1}' <<< "$REPLICAS"; then
    docker stack services "$STACK"
    exit 0
  fi
  sleep 3
done

docker stack services "$STACK"
docker stack ps "$STACK" --no-trunc
echo "Истекло время ожидания реплик стека $STACK" >&2
exit 1
