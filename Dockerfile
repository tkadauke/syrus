# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t syrus .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name syrus syrus

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Connect published images to the source repo. GHCR reads this label to link a
# newly-published package to the repository, which (a) lets the release
# workflow's built-in GITHUB_TOKEN push it with no PAT — the package is
# auto-connected on first CI publish — and (b) makes the package page link back
# here. Inherited by every `FROM base` stage, including the published worker-dev
# image. See docs/releasing.md.
LABEL org.opencontainers.image.source="https://github.com/tkadauke/syrus"

# Rails app lives here
WORKDIR /rails

# Install base packages. Notes specific to Syrus:
#   - `git` is needed at *runtime*, not just build, because the worker
#     shells out to it for every clone / commit / push.
#   - `nodejs` + `npm` are required to install the agent CLIs, which
#     the agent worker spawns per Run via AgentInvocation / CodexInvocation.
#   - `gnupg` and `ca-certificates` are needed for NodeSource's apt repo.
#   - `ffmpeg` extracts still frames from walkthrough videos at the
#     timestamps Gemini flags, so the analysis chat turn can illustrate each
#     issue (VideoWalkthroughFrameExtractor).
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.226
ARG CODEX_CLI_VERSION=0.147.0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates curl default-mysql-client ffmpeg git gnupg libjemalloc2 libvips && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @openai/codex@${CODEX_CLI_VERSION} && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# BUNDLE_WITHOUT excludes both groups so test-only gems (capybara, vcr,
# webmock, selenium-webdriver, rspec-rails, brakeman) don't ship in the
# image. Single colon-separated string per Bundler's docs.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    RAILS_LOG_TO_STDOUT="1"

# rails user lives in `base` (not just in `app`) so other stages
# downstream of base — `worker-deps` and `worker-dev` — can also
# switch to it without re-running useradd. The build stage stays
# root for gem install.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /home/rails/.syrus && \
    chown 1000:1000 /home/rails/.syrus

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential default-libmysqlclient-dev git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./
COPY plugins/ ./plugins/

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Install JavaScript dependencies for the React SPA build. node_modules
# is removed before the final image copy; the runtime image only needs
# the compiled assets in app/assets/builds.
COPY package.json package-lock.json ./
RUN npm ci

# Copy application code
COPY . .

# Build the React SPA bundle into app/assets/builds for Propshaft.
RUN npm run build

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring runtime secrets.
# These values remain runtime-owned; precompile only needs syntactically valid
# placeholders while Rails initializes production services.
RUN SYRUS_APP_HOST=syrus.invalid \
    S3_ACCESS_KEY_ID=dummy \
    S3_SECRET_ACCESS_KEY=dummy \
    S3_BUCKET=syrus-build-assets \
    S3_ENDPOINT=http://127.0.0.1:9000 \
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf node_modules


# Throw-away stage: builds whisper.cpp (CPU-only, MIT licensed,
# https://github.com/ggml-org/whisper.cpp — GitHub's canonical rename of
# ggerganov/whisper.cpp) from a pinned release tag via cmake, and downloads
# the small default dictation model. No CUDA/GPU deps; GGML_CUDA=OFF plus
# leaving every arch flag at its default keeps the CMake build portable
# across amd64/arm64. build-essential/cmake are installed only in this
# throw-away stage (not in base's shared apt layer) so they never ship in
# any final image, matching the existing `build` stage's pattern.
#
# Copied into both `app` (the k8s web pod, per bin/deploy's target=app) and
# `worker-dev` (the single-host `syrus-backend` image published by
# bin/publish-image, which docker-compose.yml also runs in the web role via
# its shared `x-app` image/x-app anchor) so chat_speech_to_text has a working
# local backend with zero operator-supplied binary/model on every Syrus
# deployment shape — not just the split-image k8s one. SYRUS_SKIP_WHISPER_BUILD=1
# skips the compile + ~148MB model download for a fast local dev loop (wired
# as the default in bin/build-local-image and bin/compose-up via
# docker-image-lib); published images (bin/publish-image, bin/deploy) never
# set it, so bundling stays mandatory for anything actually shipped.
FROM base AS whisper-build

ARG SYRUS_SKIP_WHISPER_BUILD=0
ARG WHISPER_CPP_VERSION=v1.9.2
ARG WHISPER_CPP_MODEL=ggml-base.en.bin

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    mkdir -p /opt/whisper.cpp/models && \
    if [ "$SYRUS_SKIP_WHISPER_BUILD" = "1" ]; then \
      echo "SYRUS_SKIP_WHISPER_BUILD=1 -- writing a stub whisper-cli for local dev; never set this for published images" && \
      printf '#!/bin/sh\necho "whisper-cli unavailable: image built with SYRUS_SKIP_WHISPER_BUILD=1" >&2\nexit 1\n' > /opt/whisper.cpp/whisper-cli && \
      chmod +x /opt/whisper.cpp/whisper-cli && \
      touch "/opt/whisper.cpp/models/${WHISPER_CPP_MODEL}"; \
    else \
      apt-get update -qq && \
      apt-get install --no-install-recommends -y build-essential cmake && \
      git clone --branch "$WHISPER_CPP_VERSION" --depth 1 https://github.com/ggml-org/whisper.cpp.git /tmp/whisper-cpp-src && \
      cmake -S /tmp/whisper-cpp-src -B /tmp/whisper-cpp-src/build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=OFF -DWHISPER_BUILD_EXAMPLES=ON && \
      cmake --build /tmp/whisper-cpp-src/build --config Release -j"$(nproc)" && \
      cp /tmp/whisper-cpp-src/build/bin/whisper-cli /opt/whisper.cpp/whisper-cli && \
      curl -fsSL -o "/opt/whisper.cpp/models/${WHISPER_CPP_MODEL}" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_CPP_MODEL}" && \
      rm -rf /tmp/whisper-cpp-src /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi


# Final stage for app image
FROM base AS app

# rails user already created in `base`; just switch to it.
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Bundled whisper.cpp CLI + default dictation model — see the whisper-build
# stage comment for why this is copied into both `app` and `worker-dev`.
COPY --chown=rails:rails --from=whisper-build /opt/whisper.cpp /opt/whisper.cpp

# Bake the git SHA the image was built from. .git/ is excluded via
# .dockerignore so the running container can't compute it itself —
# bin/deploy passes --build-arg GIT_SHA=$(git rev-parse --short HEAD).
# Placed late so re-baking the SHA doesn't bust the asset/gem cache.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

# Bake the release version too (bin/publish-image X.Y.Z passes it through
# the shared build helpers). Empty for dev/deploy builds — the bootstrap
# payload then omits it and the UI falls back to the git SHA.
ARG SYRUS_VERSION=""
ENV SYRUS_VERSION=$SYRUS_VERSION

# And the build timestamp (UTC ISO-8601), so the UI's BuildBadge can show
# WHEN this image was built — the fastest way to see which part of a
# diverged app/backend pair is older. Passed by bin/publish-image and
# bin/build-local-image; empty for bin/deploy / compose-up builds.
ARG SYRUS_BUILT_AT=""
ENV SYRUS_BUILT_AT=$SYRUS_BUILT_AT

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]




# ============================================================================
# Runtime cache stages — pre-compiled language runtimes for the worker.
#
# Ruby installs mise's PRECOMPILED binaries (MISE_RUBY_COMPILE=0), which cuts
# this stage from ~13 min (compiling 3.2.3 + 3.3.11 from source) to seconds.
# The prebuilt binaries are glibc-2.36-compatible — verified running on
# bookworm-slim, amd64 and arm64, with their own bundled OpenSSL/libyaml — and
# mise makes precompiled the default in 2026.8.0 anyway. The apt build deps in
# runtime-base stay: `bundle install` still compiles native gems against them.
# Python still compiles from source (~3 min). Keep each language family in its
# own stage so changing Go/Node/Python pins cannot invalidate the Ruby cache.
#
# Cross-builder cache sharing (e.g. CI on fresh runners) needs `--cache-from
# type=registry,ref=ghcr.io/tkadauke/syrus:cache` plus a matching `--cache-to`.
# The Dockerfile structure is what makes that effective.
# ============================================================================
FROM docker.io/library/debian:bookworm-slim AS runtime-base

ENV DEBIAN_FRONTEND=noninteractive \
    MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates curl \
      build-essential pkg-config \
      libffi-dev libssl-dev libyaml-dev \
      libxml2-dev libxslt-dev \
      zlib1g-dev libreadline-dev && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Pinned: unpinned installs broke when mise v2026.7.0 moved to a glibc 2.39
# baseline — newer than bookworm's 2.36 — so every cold rebuild of this stage
# started failing with `GLIBC_2.39 not found`. v2026.6.14 is the last release
# built against a bookworm-compatible glibc; bump deliberately (test with
# `docker run --rm debian:bookworm-slim` + this install line) rather than
# floating to latest.
ARG MISE_VERSION="v2026.6.14"
RUN curl -fsSL https://mise.jdx.dev/install.sh | \
      MISE_VERSION="$MISE_VERSION" MISE_INSTALL_PATH=/usr/local/bin/mise sh

FROM runtime-base AS runtime-ruby-cache

# Exact patch pins keep cache keys stable and make cold rebuilds reproducible.
# 3.4.10 matches Syrus's own .ruby-version; 3.3.11 remains useful for
# agent workspaces targeting the previous maintained Ruby line.
# MISE_RUBY_COMPILE=0 pulls prebuilt binaries instead of compiling (see the
# stage-header note); bump the mise pin deliberately if a prebuilt is missing.
ARG MISE_RUBIES="3.4.10 3.3.11"
RUN MISE_RUBY_COMPILE=0 /usr/local/bin/mise install $(for v in $MISE_RUBIES; do echo ruby@$v; done) && \
    rm -rf /opt/mise/cache /opt/mise/tmp

FROM runtime-base AS runtime-node-cache

# Use explicit majors instead of "lts lts-1" — mise's Node plugin only
# resolves `lts` (current) and named codenames (lts-iron, lts-jod, ...),
# not `lts-1`. Pinning by major (24, 22) gives us current LTS + Syrus's
# own NODE_MAJOR=22 pin, both stable across upstream LTS rotations.
ARG MISE_NODES="24 22"
RUN /usr/local/bin/mise install $(for v in $MISE_NODES; do echo node@$v; done) && \
    rm -rf /opt/mise/cache /opt/mise/tmp

FROM runtime-base AS runtime-python-cache

ARG MISE_PYTHONS="3.11"
RUN /usr/local/bin/mise install $(for v in $MISE_PYTHONS; do echo python@$v; done) && \
    rm -rf /opt/mise/cache /opt/mise/tmp

FROM runtime-base AS runtime-go-cache

ARG MISE_GO_VERSION="1.26.5"
RUN /usr/local/bin/mise install go@$MISE_GO_VERSION && \
    /usr/local/bin/mise use --global go@$MISE_GO_VERSION && \
    /usr/local/bin/mise reshim go && \
    rm -rf /opt/mise/cache /opt/mise/tmp

FROM runtime-base AS runtime-cache

COPY --from=runtime-ruby-cache /opt/mise/ /opt/mise/
COPY --from=runtime-node-cache /opt/mise/ /opt/mise/
COPY --from=runtime-python-cache /opt/mise/ /opt/mise/
COPY --from=runtime-go-cache /opt/mise/ /opt/mise/
RUN /usr/local/bin/mise reshim && \
    rm -rf /opt/mise/cache /opt/mise/tmp


# ============================================================================
# Worker deps stage — generalist tooling so the in-pod claude-code agent
# can verify its changes against arbitrary external repos (run tests,
# build assets, etc). Companion to greenacres#16; only the worker pod
# uses this variant. Web pod stays on the lean `app` stage.
#
# Critically, this stage is `FROM base`, NOT `FROM app`. The heavy apt
# install + mise copy + npm/pip install layers live ABOVE the rails-code
# COPY (which happens later in `worker-dev`). Result: changing Rails
# code only invalidates the rails-copy layer in `worker-dev`, not the
# heavy stuff here. Cache-from across builds works against this stage's
# stable hash regardless of commit-to-commit code churn.
# ============================================================================
FROM base AS worker-deps

USER root

ARG POETRY_VERSION=2.4.1
ARG UV_VERSION=0.12.3
ARG MISE_GO_VERSION="1.26.5"

# Native build deps + DB clients (no servers) + CLI tooling. Each tool
# justified in greenacres#16 / syrus#114; ripgrep+fd in particular speed
# up the agent dramatically when exploring code. The lib*-dev deps are
# kept here too (not just runtime-cache) so on-demand `mise install`
# of a non-default version inside the worker pod still has them.
#
# C++ / CMake / Qt 6 / Xvfb are included so repos like tkadauke/raytracer
# can run `cmake --preset release && ctest` inside `.syrus.yml` graders
# without sudo apt-get in `prepare:` (the worker runs as uid 1000 with
# no sudo capability). Keep GitHub mutation tools like `gh` out of the
# worker image; PR operations should go through Syrus service code.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential clang clang-format clang-tidy pkg-config \
      libffi-dev libssl-dev libyaml-dev \
      libxml2-dev libxslt-dev \
      zlib1g-dev libreadline-dev \
      default-libmysqlclient-dev libpq-dev libsqlite3-dev \
      libbenchmark-dev libgtest-dev libxkbcommon-dev libxkbcommon-x11-dev \
      sqlite3 postgresql-client default-mysql-client \
      wget openssh-client jq ripgrep fd-find less vim \
      python3 python3-pip python3-venv \
      cmake ninja-build \
      qt6-base-dev qt6-declarative-dev libgl1-mesa-dev xvfb xauth \
      doxygen graphviz lcov gcovr \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Tailscale — connectivity plugin runs the daemon in the worker container.
# The web pod uses the `app` stage and does not need the binaries.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
      | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y tailscale && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Pull pre-compiled runtimes + the mise binary from the runtime-cache
# stage. This is the layer that previously ran `mise install ...` and
# took ~13 min cold; now it's a fast COPY of artifacts that were
# compiled once and stay cached.
COPY --from=runtime-cache /opt/mise /opt/mise-seed
COPY --from=runtime-cache /opt/mise /opt/mise
COPY --from=runtime-cache /usr/local/bin/mise /usr/local/bin/mise
RUN chown -R 1000:1000 /opt/mise-seed /opt/mise

# Package managers that don't ship with their default runtime. Python
# tools live in an isolated venv so `poetry` stays executable without
# relying on Debian's PEP-668-protected system site-packages.
RUN npm install -g yarn pnpm && npm cache clean --force && \
    python3 -m venv /opt/python-tools && \
    /opt/python-tools/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/python-tools/bin/pip install --no-cache-dir \
      poetry==${POETRY_VERSION} \
      uv==${UV_VERSION} && \
    ln -s /opt/python-tools/bin/poetry /usr/local/bin/poetry && \
    ln -s /opt/python-tools/bin/uv /usr/local/bin/uv

ENV PATH="/opt/python-tools/bin:/opt/mise/shims:${PATH}" \
    MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml \
    SYRUS_MISE_GO_VERSION=${MISE_GO_VERSION}

# ============================================================================
# Worker dev stage — `worker-deps` plus the same rails code + bundle
# the `app` stage gets. Mirrors app's COPY-from-build + GIT_SHA + entry
# wiring; intentionally parallel to `app` so the two diverge only on
# the worker tooling (above) and not on runtime contract.
# ============================================================================
FROM worker-deps AS worker-dev

USER 1000:1000

RUN go version

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Bundled whisper.cpp CLI + default dictation model. worker-dev also needs
# this: it's the base for the single-host `syrus-backend` image (built by
# bin/publish-image), which docker-compose.yml runs in the web role too via
# its shared `x-app` image — not just the k8s worker pod. See the
# whisper-build stage comment for the full rationale.
COPY --chown=rails:rails --from=whisper-build /opt/whisper.cpp /opt/whisper.cpp

# Bake the git SHA the image was built from. .git/ is excluded via
# .dockerignore so the running container can't compute it itself —
# bin/deploy passes --build-arg GIT_SHA=$(git rev-parse --short HEAD).
# Placed late so re-baking the SHA doesn't bust the asset/gem cache.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

# Bake the release version too (bin/publish-image X.Y.Z passes it through
# the shared build helpers). Empty for dev/deploy builds — the bootstrap
# payload then omits it and the UI falls back to the git SHA.
ARG SYRUS_VERSION=""
ENV SYRUS_VERSION=$SYRUS_VERSION

# And the build timestamp (UTC ISO-8601), so the UI's BuildBadge can show
# WHEN this image was built — the fastest way to see which part of a
# diverged app/backend pair is older. Passed by bin/publish-image and
# bin/build-local-image; empty for bin/deploy / compose-up builds.
ARG SYRUS_BUILT_AT=""
ENV SYRUS_BUILT_AT=$SYRUS_BUILT_AT

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80

# Inherits app's posture (thrust+rails server) by default; the worker
# pod's Deployment overrides command to `bin/jobs` per greenacres#16.
CMD ["./bin/thrust", "./bin/rails", "server"]
