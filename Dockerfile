# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t syrus .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name syrus syrus

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.2.3
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. Notes specific to Syrus:
#   - `git` is needed at *runtime*, not just build, because the worker
#     shells out to it for every clone / commit / push.
#   - `nodejs` + `npm` are required to install the agent CLIs, which
#     the agent worker spawns per Run via AgentInvocation / CodexInvocation.
#   - `gnupg` and `ca-certificates` are needed for NodeSource's apt repo.
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.126
ARG CODEX_CLI_VERSION=0.129.0
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates curl default-mysql-client git gnupg libjemalloc2 libvips && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @openai/codex@${CODEX_CLI_VERSION} && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

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
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential default-libmysqlclient-dev git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

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




# Final stage for app image
FROM base AS app

# rails user already created in `base`; just switch to it.
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Bake the git SHA the image was built from. .git/ is excluded via
# .dockerignore so the running container can't compute it itself —
# bin/deploy passes --build-arg GIT_SHA=$(git rev-parse --short HEAD).
# Placed late so re-baking the SHA doesn't bust the asset/gem cache.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

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
    MISE_DATA_DIR=/opt/mise

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates curl \
      build-essential pkg-config \
      libffi-dev libssl-dev libyaml-dev \
      libxml2-dev libxslt-dev \
      zlib1g-dev libreadline-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

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
# 3.2.3 matches Syrus's own .ruby-version; 3.3.11 is the current Ruby 3.3 line.
# MISE_RUBY_COMPILE=0 pulls prebuilt binaries instead of compiling (see the
# stage-header note); bump the mise pin deliberately if a prebuilt is missing.
ARG MISE_RUBIES="3.2.3 3.3.11"
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

ARG MISE_GO_VERSION="1.26.4"
RUN /usr/local/bin/mise install go@$MISE_GO_VERSION && \
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

ARG POETRY_VERSION=2.3.4
ARG UV_VERSION=0.11.7
ARG MISE_GO_VERSION="1.26.4"

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
RUN apt-get update -qq && \
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
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Pull pre-compiled runtimes + the mise binary from the runtime-cache
# stage. This is the layer that previously ran `mise install ...` and
# took ~13 min cold; now it's a fast COPY of artifacts that were
# compiled once and stay cached.
COPY --from=runtime-cache /opt/mise /opt/mise
COPY --from=runtime-cache /usr/local/bin/mise /usr/local/bin/mise
RUN chown -R 1000:1000 /opt/mise

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

ENV PATH="/opt/mise/installs/go/${MISE_GO_VERSION}/bin:/opt/python-tools/bin:/opt/mise/shims:${PATH}" \
    MISE_DATA_DIR=/opt/mise

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

# Bake the git SHA the image was built from. .git/ is excluded via
# .dockerignore so the running container can't compute it itself —
# bin/deploy passes --build-arg GIT_SHA=$(git rev-parse --short HEAD).
# Placed late so re-baking the SHA doesn't bust the asset/gem cache.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80

# Inherits app's posture (thrust+rails server) by default; the worker
# pod's Deployment overrides command to `bin/jobs` per greenacres#16.
CMD ["./bin/thrust", "./bin/rails", "server"]
