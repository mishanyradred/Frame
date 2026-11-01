FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py .
RUN useradd --system --uid 10001 worker \
    && mkdir -p /data/raw /data/videos \
    && chown -R 10001:10001 /data
USER worker

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "from pathlib import Path; import time; assert time.time() - Path('/tmp/worker-heartbeat').stat().st_mtime < 30"

CMD ["python", "worker.py"]
