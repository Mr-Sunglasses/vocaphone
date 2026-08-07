# syntax=docker/dockerfile:1.7

ARG WHISPER_CPP_VERSION=v1.9.1
ARG GGML_NATIVE=OFF

FROM debian:bookworm-slim AS whisper-builder
ARG WHISPER_CPP_VERSION
ARG GGML_NATIVE
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential ca-certificates cmake curl libopenblas-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl --fail --location --show-error \
      "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/${WHISPER_CPP_VERSION}.tar.gz" \
      | tar --extract --gzip --strip-components=1
RUN cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_NATIVE=${GGML_NATIVE} \
      -DGGML_BLAS=ON \
      -DGGML_BLAS_VENDOR=OpenBLAS \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON \
    && cmake --build build --config Release --target whisper-cli --parallel

FROM ghcr.io/astral-sh/uv:0.8.0 AS uv

FROM python:3.12-slim-bookworm AS runtime
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates ffmpeg libgomp1 libopenblas0-pthread libportaudio2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /uvx /bin/
COPY --from=whisper-builder /src/build/bin/whisper-cli /usr/local/bin/whisper-cli
COPY --from=whisper-builder /src/build/bin/*.so* /usr/local/lib/
RUN ldconfig

WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --extra engines --no-install-project
COPY app ./app
RUN uv sync --frozen --no-dev --extra engines \
    && groupadd --gid 10001 vocaphone \
    && useradd --uid 10001 --gid vocaphone --no-create-home \
      --home-dir /app --shell /usr/sbin/nologin vocaphone \
    && mkdir --parents /data \
    && chown --recursive vocaphone:vocaphone /data /app

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    VOCAPHONE_BIND_HOST=0.0.0.0 \
    VOCAPHONE_PORT=8765 \
    VOCAPHONE_DATA_DIR=/data \
    VOCAPHONE_MODELS_DIR=/data/models \
    VOCAPHONE_CONFIG_FILE=/data/config/config.json \
    VOCAPHONE_TOKEN_FILE=/run/secrets/vocaphone_token \
    VOCAPHONE_WHISPER_BINARY=/usr/local/bin/whisper-cli \
    VOCAPHONE_ENGINE=auto

USER vocaphone
EXPOSE 8765
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8765/health/live', timeout=3)"]
ENTRYPOINT ["vocaphone-server"]
