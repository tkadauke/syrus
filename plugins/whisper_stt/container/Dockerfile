# syntax=docker/dockerfile:1

# whisper.cpp's whisper-server daemon for the whisper_stt plugin. The build
# stage compiles the pinned server binary and downloads the default model; the
# runtime stage keeps only the binary, model, ffmpeg, and its shared-library
# dependencies.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25-alpine AS gateway-build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /whisper-gateway .

FROM docker.io/library/debian:bookworm-slim AS whisper-build

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
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_CUDA=OFF \
      -DGGML_NATIVE=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build --config Release --target whisper-server -j"$(nproc)" && \
    ./models/download-ggml-model.sh base.en

FROM docker.io/library/debian:bookworm-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eu; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates ffmpeg libgomp1 && \
    adduser --disabled-password --gecos "" --uid 1000 whisper && \
    mkdir -p /opt/whisper/models /tmp/whisper-stt && \
    chown -R whisper:whisper /opt/whisper /tmp/whisper-stt && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=whisper-build /src/build/bin/whisper-server /usr/local/bin/whisper-server
COPY --from=whisper-build /src/models/ggml-base.en.bin /opt/whisper/models/ggml-base.en.bin
COPY --from=gateway-build /whisper-gateway /usr/local/bin/whisper-gateway

USER whisper
WORKDIR /tmp/whisper-stt
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["/usr/local/bin/whisper-gateway", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/whisper-gateway"]
