"""Воркер транскодирования: забирает задачи из Redis и нарезает видео в HLS с двумя профилями качества."""

import json
import logging
import os
import signal
import subprocess
import shutil
import tempfile
import threading
import time
from pathlib import Path

import psycopg
import redis

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://frame:frame@db:5432/frame")
REDIS_URL = os.getenv("REDIS_URL", "redis://queue:6379/0")
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
QUEUE_NAME = os.getenv("QUEUE_NAME", "transcode:jobs")

# Профили адаптивного битрейта: имя, высота кадра, битрейт видео, битрейт звука
RENDITIONS = [
    ("720p", 720, "2800k", "128k"),
    ("360p", 360, "800k", "96k"),
]

log = logging.getLogger("frame.transcoder")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

queue = redis.Redis.from_url(REDIS_URL, decode_responses=True)
running = True


def stop(*_):
    global running
    log.info("получен сигнал остановки, завершаю после текущей задачи")
    running = False


def update_video(video_id: str, **fields) -> None:
    columns = ", ".join(f"{name} = %s" for name in fields)
    with psycopg.connect(DATABASE_URL) as conn:
        conn.execute(
            f"UPDATE videos SET {columns}, updated_at = now() WHERE id = %s",
            (*fields.values(), video_id),
        )


def probe(path: str) -> tuple:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", path],
        check=True,
        capture_output=True,
        text=True,
    )
    info = json.loads(result.stdout)
    types = {stream["codec_type"] for stream in info.get("streams", [])}
    if "video" not in types:
        raise ValueError("в файле нет видеопотока")
    return float(info["format"].get("duration", 0)), "audio" in types


def build_hls_command(src: str, out_dir: str, has_audio: bool) -> list:
    splits = "".join(f"[v{i}]" for i in range(len(RENDITIONS)))
    scales = ";".join(f"[v{i}]scale=-2:{height}[v{i}out]" for i, (_, height, _, _) in enumerate(RENDITIONS))
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", src,
           "-filter_complex", f"[0:v]split={len(RENDITIONS)}{splits};{scales}"]
    stream_map = []
    for i, (name, _, video_bitrate, audio_bitrate) in enumerate(RENDITIONS):
        cmd += ["-map", f"[v{i}out]", f"-c:v:{i}", "libx264", f"-b:v:{i}", video_bitrate]
        if has_audio:
            cmd += ["-map", "0:a:0", f"-c:a:{i}", "aac", f"-b:a:{i}", audio_bitrate]
            stream_map.append(f"v:{i},a:{i},name:{name}")
        else:
            stream_map.append(f"v:{i},name:{name}")
    cmd += [
        "-preset", "veryfast", "-g", "48", "-sc_threshold", "0",
        "-f", "hls", "-hls_time", "4", "-hls_playlist_type", "vod",
        "-hls_segment_filename", os.path.join(out_dir, "%v_%03d.ts"),
        "-master_pl_name", "master.m3u8",
        "-var_stream_map", " ".join(stream_map),
        os.path.join(out_dir, "%v.m3u8"),
    ]
    return cmd


def process(job: dict) -> None:
    video_id, raw_key = job["video_id"], job["raw_key"]
    log.info("начато транскодирование %s", video_id)
    update_video(video_id, status="processing", error=None)
    started = time.perf_counter()

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "source")
        out_dir = os.path.join(tmp, "hls")
        os.makedirs(out_dir)
        shutil.copyfile(DATA_DIR / "raw" / raw_key, src)

        duration, has_audio = probe(src)
        subprocess.run(build_hls_command(src, out_dir, has_audio), check=True, capture_output=True, text=True)
        subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", str(min(duration * 0.1, 3.0)),
             "-i", src, "-frames:v", "1", "-vf", "scale=640:-2", os.path.join(out_dir, "thumb.jpg")],
            check=True, capture_output=True, text=True,
        )
        shutil.copytree(out_dir, DATA_DIR / "videos" / video_id, dirs_exist_ok=True)

    update_video(
        video_id,
        status="ready",
        hls_path=f"{video_id}/master.m3u8",
        thumb_path=f"{video_id}/thumb.jpg",
        duration_sec=round(duration, 2),
    )
    log.info("видео %s готово за %.1f с", video_id, time.perf_counter() - started)


def main() -> None:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    def heartbeat():
        while running:
            Path("/tmp/worker-heartbeat").touch()
            time.sleep(5)
    threading.Thread(target=heartbeat, daemon=True).start()
    log.info("воркер запущен, очередь %s", QUEUE_NAME)

    while running:
        try:
            item = queue.brpop(QUEUE_NAME, timeout=5)
        except redis.RedisError as exc:
            log.warning("очередь недоступна: %s", exc)
            time.sleep(2)
            continue
        if not item:
            continue

        job = json.loads(item[1])
        try:
            process(job)
        except Exception as exc:  # noqa: BLE001 — любая ошибка должна пометить видео как failed
            detail = exc.stderr if isinstance(exc, subprocess.CalledProcessError) else str(exc)
            log.error("ошибка транскодирования %s: %s", job.get("video_id"), detail)
            try:
                update_video(job["video_id"], status="failed", error=str(detail)[:500])
            except psycopg.Error:
                log.exception("не удалось записать статус failed")


if __name__ == "__main__":
    main()
