# syntax=docker/dockerfile:1
#
# Boondock-Edge-API production image.
#
# Build context for this Dockerfile MUST be the Boondock-Edge-API submodule
# directory (see docker-compose.api.yml / docker-compose.yml):
#   build:
#     context: ./Boondock-Edge-API
#     dockerfile: ../docker/api.Dockerfile
# so the submodule itself never needs a Dockerfile and stays pristine.

FROM python:3.11-slim-bookworm AS runtime

LABEL org.opencontainers.image.title="boondock-edge-api" \
      org.opencontainers.image.source="https://github.com/Boondock-Echo/Boondock-Edge-API"

# --- System dependencies -------------------------------------------------
# build-essential/python3-dev: fallback in case a prebuilt wheel isn't
#   published for the target CPU arch (e.g. bcrypt/greenlet on arm64).
# libportaudio2: runtime lib backing the `sounddevice` package in requirements.txt.
# libsndfile1, ffmpeg: audio decode support used by recording/transcription paths.
# curl: used by the HEALTHCHECK below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        python3-dev \
        libportaudio2 \
        libsndfile1 \
        ffmpeg \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /api

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    BOONDOCK_DATA_ROOT=/data \
    FLASK_PORT=4000

# --- Python dependencies --------------------------------------------------
# NOTE: requirements.txt in Boondock-Edge-API is currently saved as UTF-16LE
# (with BOM) rather than UTF-8 (verified with `xxd`). pip's requirements-file
# parser does not handle UTF-16, so this step transcodes a COPY'd *working
# copy* inside this image layer to UTF-8. The submodule's file on disk/in git
# history is never touched. Re-verify this is still required whenever
# requirements.txt changes upstream (if it's already UTF-8, this block is a
# harmless no-op).
COPY requirements.txt ./requirements.txt
RUN python3 - <<'PY'
raw = open("requirements.txt", "rb").read()
text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8")
open("requirements.txt", "w", encoding="utf-8", newline="\n").write(text)
PY
RUN pip install --no-cache-dir -r requirements.txt

# --- Application code -----------------------------------------------------
COPY . .

# Persistent data (db/, recordings/, logs/, device_settings/, docs/) lives
# outside the image on a mounted volume — created here so the app can boot
# even before the volume is first populated.
RUN mkdir -p /data

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${FLASK_PORT}/api/health/system?current=true" || exit 1

# run.py always drives the app via socketio.run() internally (selecting
# gevent/threading based on PRODUCTION_MODE / PRODUCTION_SERVER /
# SOCKETIO_ASYNC_MODE) — it does NOT hand off to gunicorn/waitress as a WSGI
# entrypoint despite those being listed in requirements.txt, so `python
# run.py` is the correct and only production entrypoint here.
CMD ["python", "run.py"]
