# syntax=docker/dockerfile:1

# The Browser Plugin Runtime service: @playwright/mcp, fronted by a small Go
# bridge that adds the /healthz path the service contract needs (see
# internal/bridge). Chromium's shared-library requirements rule out an
# Alpine/musl runtime image the way Git Mirror uses one for its plain Go
# binary, so this stays on Debian, matching the same
# playwright@/@playwright/mcp install Syrus's own worker image runs
# (Dockerfile's worker-deps stage) -- keep the pinned versions below in sync
# with that stage when bumping either.

# The Go build runs on the build host and cross-compiles, so a multi-arch
# build never compiles under QEMU emulation.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /browser-bridge .

FROM docker.io/library/debian:bookworm-slim

ARG NODE_MAJOR=22
ARG PLAYWRIGHT_VERSION=1.57.0
ARG PLAYWRIGHT_MCP_VERSION=0.0.79
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# Do not use BuildKit apt cache mounts here. Playwright's `install --with-deps`
# drives apt internally, and a full/stale cache mount makes apt fail with
# "No space left on device" before it can refresh package lists (same
# constraint as the root Dockerfile's worker-deps stage).
RUN set -eu; \
    cleanup_apt_cache() { rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; }; \
    cleanup_apt_cache; \
    trap cleanup_apt_cache EXIT; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates curl gnupg && \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    npm install -g "playwright@${PLAYWRIGHT_VERSION}" "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" && \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium && \
    mkdir -p /opt/syrus-browser && \
    ln -s "$(find "${PLAYWRIGHT_BROWSERS_PATH}" -path '*/chrome-linux*/chrome' -type f | sort | tail -n 1)" /opt/syrus-browser/chromium && \
    adduser --disabled-password --gecos "" --uid 1000 browser && \
    chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}" && \
    chmod a+rx /opt/syrus-browser/chromium && \
    npm cache clean --force

COPY --from=build /browser-bridge /usr/local/bin/browser-bridge

USER browser
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["/usr/local/bin/browser-bridge", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/browser-bridge"]
