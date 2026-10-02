# syntax=docker/dockerfile:1

# whisper.cpp's whisper-server daemon for the whisper_stt plugin. The build
# stage compiles the pinned server binary and downloads the default model; the
# runtime stage keeps only the binary, model, ffmpeg, and its shared-library
# dependencies.
FROM docker.io/library/debian:bookworm-slim AS build

ARG WHISPER_CPP_VERSION=v1.9.3

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eu; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates cmake g++ git make python3 wget && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

WORKDIR /src
RUN git clone --depth 1 --branch "${WHISPER_CPP_VERSION}" https://github.com/ggml-org/whisper.cpp.git . && \
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_CUDA=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build --config Release --target whisper-server -j"$(nproc)" && \
    ./models/download-ggml-model.sh base.en

FROM docker.io/library/debian:bookworm-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eu; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates curl ffmpeg libgomp1 && \
    adduser --disabled-password --gecos "" --uid 1000 whisper && \
    mkdir -p /opt/whisper/models /tmp/whisper-stt && \
    chown -R whisper:whisper /opt/whisper /tmp/whisper-stt && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=build /src/build/bin/whisper-server /usr/local/bin/whisper-server
COPY --from=build /src/models/ggml-base.en.bin /opt/whisper/models/ggml-base.en.bin

USER whisper
WORKDIR /tmp/whisper-stt
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["curl", "-fsS", "http://127.0.0.1:8080/health"]
ENTRYPOINT ["/usr/local/bin/whisper-server"]
CMD ["--host", "0.0.0.0", "--port", "8080", "--model", "/opt/whisper/models/ggml-base.en.bin", "--convert", "--tmp-dir", "/tmp/whisper-stt"]
