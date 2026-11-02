"""Frame API: каталог видео, загрузка исходников и постановка задач на транскодирование."""

import json
import logging
import os
import re
import shutil
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

import psycopg
import redis
from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import Response
from psycopg.rows import DictRow, dict_row

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://frame:frame@db:5432/frame")
REDIS_URL = os.getenv("REDIS_URL", "redis://queue:6379/0")
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
QUEUE_NAME = os.getenv("QUEUE_NAME", "transcode:jobs")
MEDIA_URL = os.getenv("MEDIA_URL", "/media")

log = logging.getLogger("frame.api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

queue = redis.Redis.from_url(REDIS_URL, decode_responses=True)


def db() -> psycopg.Connection[DictRow]:
    return psycopg.Connection[DictRow].connect(DATABASE_URL, row_factory=dict_row)


def wait_for_dependencies(attempts: int = 30, delay: float = 2.0) -> None:
    """В Swarm depends_on не работает, поэтому сервис сам дожидается БД и очереди."""
    for attempt in range(1, attempts + 1):
        try:
            with db() as conn:
                conn.execute("SELECT 1")
            queue.ping()
            return
        except (psycopg.Error, redis.RedisError) as exc:
            log.warning("зависимости недоступны (%s/%s): %s", attempt, attempts, exc)
            time.sleep(delay)
    raise RuntimeError("не удалось подключиться к БД или очереди")


@asynccontextmanager
async def lifespan(_: FastAPI):
    wait_for_dependencies()
    for folder in ("raw", "videos"):
        (DATA_DIR / folder).mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="Frame API", version="1.0.0", lifespan=lifespan, docs_url="/api/docs", openapi_url="/api/openapi.json")


def serialize(row: dict) -> dict:
    row["id"] = str(row["id"])
    row["created_at"] = row["created_at"].isoformat()
    row["duration_sec"] = float(row["duration_sec"]) if row["duration_sec"] is not None else None
    hls_path, thumb_path = row.pop("hls_path"), row.pop("thumb_path")
    row["hls_url"] = f"{MEDIA_URL}/{hls_path}" if hls_path else None
    row["thumbnail_url"] = f"{MEDIA_URL}/{thumb_path}" if thumb_path else None
    return row


VIDEO_SELECT = """
    SELECT v.id, v.title, v.description, c.slug AS category, c.name AS category_name,
           v.status, v.error, v.duration_sec, v.hls_path, v.thumb_path, v.created_at
    FROM videos v JOIN categories c ON c.id = v.category_id
"""


@app.get("/api/health")
def health():
    checks = {}
    try:
        with db() as conn:
            conn.execute("SELECT 1")
        checks["db"] = "ok"
    except psycopg.Error as exc:
        checks["db"] = str(exc)
    try:
        queue.ping()
        checks["queue"] = "ok"
    except redis.RedisError as exc:
        checks["queue"] = str(exc)
    checks["files"] = "ok" if os.access(DATA_DIR / "raw", os.W_OK) else "unavailable"
    healthy = all(value == "ok" for value in checks.values())
    if not healthy:
        raise HTTPException(status_code=503, detail=checks)
    return {"status": "ok", **checks}


@app.get("/api/categories")
def list_categories():
    with db() as conn:
        return conn.execute("SELECT slug, name FROM categories ORDER BY id").fetchall()


@app.get("/api/videos")
def list_videos(
    category: str | None = None,
    status: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
):
    query, params = VIDEO_SELECT + " WHERE TRUE", []
    if category:
        query += " AND c.slug = %s"
        params.append(category)
    if status:
        query += " AND v.status = %s"
        params.append(status)
    query += " ORDER BY v.created_at DESC LIMIT %s"
    params.append(min(limit, 200))
    with db() as conn:
        return [serialize(row) for row in conn.execute(query, params).fetchall()]


@app.get("/api/videos/{video_id}")
def get_video(video_id: uuid.UUID):
    with db() as conn:
        row = conn.execute(VIDEO_SELECT + " WHERE v.id = %s", (video_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="видео не найдено")
    return serialize(row)


@app.post("/api/videos", status_code=201)
def upload_video(
    title: Annotated[str, Form(min_length=1, max_length=200)],
    category: Annotated[str, Form()],
    file: Annotated[UploadFile, File()],
    description: Annotated[str, Form()] = "",
):
    if not (file.content_type or "").startswith("video/"):
        raise HTTPException(status_code=415, detail="ожидается видеофайл")

    with db() as conn:
        cat = conn.execute("SELECT id FROM categories WHERE slug = %s", (category,)).fetchone()
        if not cat:
            raise HTTPException(status_code=400, detail=f"неизвестная категория: {category}")

        video_id = uuid.uuid4()
        filename = re.sub(r"[^A-Za-z0-9._-]", "_", Path(file.filename or "source").name)
        if filename in (".", ".."):
            filename = "source"
        raw_key = f"{video_id}/{filename}"
        source = DATA_DIR / "raw" / raw_key
        source.parent.mkdir(parents=True)
        with source.open("wb") as output:
            shutil.copyfileobj(file.file, output)

        conn.execute(
            "INSERT INTO videos (id, title, description, category_id, raw_key) VALUES (%s, %s, %s, %s, %s)",
            (video_id, title, description, cat["id"], raw_key),
        )

    queue.lpush(QUEUE_NAME, json.dumps({"video_id": str(video_id), "raw_key": raw_key}))
    log.info("видео %s загружено и поставлено в очередь", video_id)
    return get_video(video_id)


@app.delete("/api/videos/{video_id}", status_code=204)
def delete_video(video_id: uuid.UUID):
    with db() as conn:
        deleted = conn.execute(
            "DELETE FROM videos WHERE id = %s AND status IN ('ready', 'failed') RETURNING id",
            (video_id,),
        ).fetchone()
        if not deleted and conn.execute("SELECT id FROM videos WHERE id = %s", (video_id,)).fetchone():
            raise HTTPException(status_code=409, detail="Дождитесь завершения обработки видео")
    if not deleted:
        raise HTTPException(status_code=404, detail="видео не найдено")
    for folder in ("raw", "videos"):
        shutil.rmtree(DATA_DIR / folder / str(video_id), ignore_errors=True)
    return Response(status_code=204)
