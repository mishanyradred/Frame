#!/usr/bin/env bash
# Сквозная проверка развёрнутой системы: nginx → API → БД, очередь и общий том → FFmpeg.
# Генерирует тестовый ролик, загружает его через API и ждёт готовый HLS-плейлист.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

BASE_URL="${BASE_URL:-http://localhost:${HTTP_PORT:-8080}}"
TRANSCODER_IMAGE="${TRANSCODER_IMAGE:-frame-transcoder:local}"
TIMEOUT="${TIMEOUT:-180}"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

step "Ожидание готовности API ($BASE_URL)"
for _ in $(seq 1 60); do
  curl -fsS "$BASE_URL/api/health" > /dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/api/health" || fail "API не отвечает"

step "Проверка клиентской части"
curl -fsS "$BASE_URL/" | grep -q "<title>Frame" || fail "главная страница не отдаётся"

step "Проверка справочника категорий"
curl -fsS "$BASE_URL/api/categories" | grep -q '"news"' || fail "нет категории news"

step "Генерация тестового видео (5 с, 1280x720, звук 440 Гц)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
docker run --rm --user "$(id -u):$(id -g)" -v "$WORKDIR:/out" --entrypoint ffmpeg "$TRANSCODER_IMAGE" \
  -hide_banner -loglevel error \
  -f lavfi -i testsrc=duration=5:size=1280x720:rate=25 \
  -f lavfi -i sine=frequency=440:duration=5 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /out/sample.mp4

step "Загрузка видео через API"
RESPONSE="$(curl -fsS -F "title=Smoke test" -F "category=news" -F "description=CI/CD проверка" \
  -F "file=@$WORKDIR/sample.mp4;type=video/mp4" "$BASE_URL/api/videos")"
VIDEO_ID="$(echo "$RESPONSE" | json '["id"]')"
echo "id=$VIDEO_ID"

step "Ожидание транскодирования (до ${TIMEOUT} с)"
STATUS=""
for _ in $(seq 1 $((TIMEOUT / 3))); do
  STATUS="$(curl -fsS "$BASE_URL/api/videos/$VIDEO_ID" | json '["status"]')"
  [[ "$STATUS" == "ready" || "$STATUS" == "failed" ]] && break
  sleep 3
done
echo "status=$STATUS"
[[ "$STATUS" == "ready" ]] || fail "видео не обработано: $(curl -fsS "$BASE_URL/api/videos/$VIDEO_ID")"

step "Проверка HLS-плейлиста и превью"
MASTER="$(curl -fsS "$BASE_URL/media/$VIDEO_ID/master.m3u8")"
echo "$MASTER"
grep -q "720p.m3u8" <<< "$MASTER" || fail "нет профиля 720p"
grep -q "360p.m3u8" <<< "$MASTER" || fail "нет профиля 360p"
for PROFILE in 720p 360p; do
  PLAYLIST="$(curl -fsS "$BASE_URL/media/$VIDEO_ID/$PROFILE.m3u8")"
  SEGMENT="$(awk 'NF && !/^#/ {gsub(/\r/, ""); print; exit}' <<< "$PLAYLIST")"
  [[ -n "$SEGMENT" ]] || fail "нет сегментов $PROFILE"
  curl -fsS "$BASE_URL/media/$VIDEO_ID/$SEGMENT" -o "$WORKDIR/$PROFILE.ts"
  [[ -s "$WORKDIR/$PROFILE.ts" ]] || fail "пустой сегмент $PROFILE"
done
curl -fsS -o /dev/null "$BASE_URL/media/$VIDEO_ID/thumb.jpg" || fail "нет превью"

step "Проверка запрета записи в хранилище извне"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data "x" "$BASE_URL/media/$VIDEO_ID/hack.txt")"
[[ "$CODE" == "403" ]] || fail "запись через /media не запрещена (код $CODE)"

step "Удаление тестового видео"
curl -fsS -X DELETE "$BASE_URL/api/videos/$VIDEO_ID"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/videos/$VIDEO_ID")"
[[ "$CODE" == "404" ]] || fail "запись видео осталась после удаления"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/media/$VIDEO_ID/master.m3u8")"
[[ "$CODE" == "404" ]] || fail "файлы видео остались после удаления"

printf '\nВсе проверки пройдены\n'
