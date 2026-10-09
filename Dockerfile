# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t syrus .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name syrus syrus

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim-trixie AS base

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
#   - `nodejs` + `npm` are required to install the npm-packaged agent CLIs,
#     which the agent worker spawns per Run via AgentInvocation. Muse Code is
#     installed below through Meta's launcher so it can fetch its native binary.
#   - `gnupg` and `ca-certificates` are needed for NodeSource's apt repo.
#   - `ffmpeg` extracts still frames from walkthrough videos at the
#     timestamps Gemini flags, so the analysis chat turn can illustrate each
#     issue (VideoWalkthroughFrameExtractor).
#   - `pigz` is a multi-threaded gzip the worker prefers (at compression
#     level 1) when streaming prepared-workspace archives to object storage
#     (PreparedWorkspaceArchive); it falls back to plain `gzip -1` when
#     absent, so this is a speed optimization, not a hard dependency.
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.289
ARG CODEX_CLI_VERSION=0.160.0
ARG MUSE_LAUNCHER_URL=https://api.meta.ai/muse-launcher.sh
ARG ANTIGRAVITY_CLI_VERSION=1.2.1
ARG ANTIGRAVITY_CLI_BUILD=5123043593420800
ARG ANTIGRAVITY_CLI_LINUX_AMD64_SHA512=0629fe69e6949b35707935ef35da016074ea29a5d989a05f740713e0a9e927bf52ff1eada0204d3338779a469c938b6b7c5c44de2d296e5e8db255d26568de38
ARG ANTIGRAVITY_CLI_LINUX_ARM64_SHA512=f6dd6057a82dcbc4ab0878d99c4b84cfc45c3e2f12647eaf435322ecdd18d0190620bca943185f542431b93f34f5ea19cf84e8fdb902e64529e110bfa0a5a46f
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eu; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates curl default-mysql-client ffmpeg git gnupg libjemalloc2 libvips pigz && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @openai/codex@${CODEX_CLI_VERSION} && \
    mkdir -p /opt/muse/bin && \
    curl -fsSL "${MUSE_LAUNCHER_URL}" -o /opt/muse/bin/muse && \
    chmod 0755 /opt/muse/bin/muse && \
    MUSE_LAUNCHER_INSTALL=1 /opt/muse/bin/muse && \
    MUSE_NO_AUTO_UPDATE=1 /opt/muse/bin/muse --version && \
    case "$(dpkg --print-architecture)" in \
      amd64) antigravity_dir=x64; antigravity_arch=x64; antigravity_sha512="${ANTIGRAVITY_CLI_LINUX_AMD64_SHA512}" ;; \
      arm64) antigravity_dir=arm; antigravity_arch=arm64; antigravity_sha512="${ANTIGRAVITY_CLI_LINUX_ARM64_SHA512}" ;; \
      *) echo "unsupported architecture for Antigravity CLI: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac && \
    antigravity_tarball="/tmp/antigravity-cli.tar.gz" && \
    curl -fsSL -o "${antigravity_tarball}" \
      "https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/linux-${antigravity_dir}/cli_linux_${antigravity_arch}.tar.gz" && \
    echo "${antigravity_sha512}  ${antigravity_tarball}" | sha512sum -c - && \
    tar -xzf "${antigravity_tarball}" -C /tmp antigravity && \
    install -m 0755 /tmp/antigravity /usr/local/bin/agy && \
    rm -f "${antigravity_tarball}" /tmp/antigravity && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# BUNDLE_WITHOUT excludes both groups so test-only gems (capybara, vcr,
# webmock, selenium-webdriver, rspec-rails, brakeman) don't ship in the
# image. Single colon-separated string per Bundler's docs.
ENV PATH="/opt/muse/bin:${PATH}" \
    MUSE_NO_AUTO_UPDATE="1" \
    RAILS_ENV="production" \
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
# Every bundled plugin's gemspec is `Syrus.plugin_gemspec(__FILE__)`, which
# require_relatives this file. Bundler evaluates every bundled plugin gemspec during
# `bundle install`, so it has to be here before that runs -- long before
# `COPY . .` brings the rest of lib/ in. Kept to the single file the gemspecs
# need so the layer cache does not turn over on unrelated lib/ edits.
# Guarded by spec/architecture/docker_gemspec_requires_spec.rb.
COPY lib/syrus/plugin_gemspec.rb ./lib/syrus/plugin_gemspec.rb

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

# Build the React SPA bundle into app/assets/builds for Propshaft. Jemalloc is
# a runtime Ruby optimization, but Node/Vite native bundler code has crashed
# under it on Linux/arm64 during chunk rendering.
RUN env -u LD_PRELOAD VITE_BUILD_SOURCEMAP=false npm run build

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

# Build the same Go CLI shipped by bin/release-cli. Keep this in its own
# source-thin stage so Go module downloads cache independently from Rails and
# asset changes, and so the final app/worker images receive only the static
# binary.
FROM docker.io/library/golang:1.26.5-bookworm AS cli-build

WORKDIR /src

COPY go.work go.work.sum ./
COPY cli/go.mod cli/go.sum ./cli/
COPY plugins/scheduled_tasks/cli/go.mod ./plugins/scheduled_tasks/cli/
COPY plugins/k8s_cluster/cli/go.mod ./plugins/k8s_cluster/cli/
COPY plugins/credential_store/cli/go.mod ./plugins/credential_store/cli/
COPY plugins/global_search/cli/go.mod ./plugins/global_search/cli/
COPY plugins/design_docs/cli/go.mod ./plugins/design_docs/cli/
COPY plugins/spending_insights/cli/go.mod ./plugins/spending_insights/cli/

RUN --mount=type=cache,target=/go/pkg/mod \
    cd cli && GOWORK=off go mod download

COPY cli/ ./cli/
COPY plugins/scheduled_tasks/cli/ ./plugins/scheduled_tasks/cli/
COPY plugins/k8s_cluster/cli/ ./plugins/k8s_cluster/cli/
COPY plugins/credential_store/cli/ ./plugins/credential_store/cli/
COPY plugins/global_search/cli/ ./plugins/global_search/cli/
COPY plugins/design_docs/cli/ ./plugins/design_docs/cli/
COPY plugins/spending_insights/cli/ ./plugins/spending_insights/cli/

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eu; \
    target_os="${TARGETOS:-linux}"; \
    target_arch="${TARGETARCH:-$(go env GOARCH)}"; \
    cd cli; \
    env GOWORK=off CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" \
      go build -trimpath -ldflags="-s -w" -o /usr/local/bin/syrus .

# Final stage for app image
FROM base AS app

# rails user already created in `base`; just switch to it.
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=root:root --from=cli-build /usr/local/bin/syrus /usr/local/bin/syrus
RUN /usr/local/bin/syrus --help >/dev/null
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

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
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 CMD if [ -n "$SYRUS_ROLE" ] && [ "$SYRUS_ROLE" != "web" ]; then exit 0; fi; curl -fsS http://127.0.0.1/readyz >/dev/null || exit 1
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
ARG MULL_LLVM_VERSION=18
ARG ANDROID_CMDLINE_TOOLS_VERSION=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ARG ANDROID_PLATFORM_VERSION=android-36
ARG ANDROID_BUILD_TOOLS_VERSION=36.0.0

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_USER_HOME=/home/rails/.android \
    ANDROID_PREFS_ROOT=/home/rails/.android \
    ANDROID_AVD_HOME=/home/rails/.android/avd

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
#
# Mull is included here rather than split to a separate worker capability
# image because the recurring mutation-testing task is still scheduled on the
# normal Linux worker pool. Keep the Mull package and clang package on the
# same LLVM major; mismatches fail when Mull loads the compiler plugin.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eu; \
    . /etc/os-release; \
    curl -fsSL https://dl.cloudsmith.io/public/mull-project/mull-stable/gpg.41DB35380DE6BD6F.key | \
      gpg --dearmor -o /usr/share/keyrings/mull-project-mull-stable-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/mull-project-mull-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/mull-project/mull-stable/deb/${ID} ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/mull-project-mull-stable.list; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential clang clang-${MULL_LLVM_VERSION} clang-format clang-tidy pkg-config \
      mull-${MULL_LLVM_VERSION} \
      libffi-dev libssl-dev libyaml-dev \
      libxml2-dev libxslt-dev \
      zlib1g-dev libreadline-dev \
      default-libmysqlclient-dev libpq-dev libsqlite3-dev \
      libbenchmark-dev libgtest-dev libxkbcommon-dev libxkbcommon-x11-dev \
      sqlite3 postgresql-client default-mysql-client \
      wget unzip openssh-client jq ripgrep fd-find less vim \
      python3 python3-pip python3-venv \
      default-jre-headless \
      cmake ninja-build \
      qt6-base-dev qt6-declarative-dev libgl1-mesa-dev xvfb xauth \
      doxygen graphviz lcov gcovr \
    && ln -sf "/usr/bin/mull-runner-${MULL_LLVM_VERSION}" /usr/local/bin/mull-runner \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Android SDK command-line baseline for Android plugin graders and emulator
# runtime sessions. A JDK/Gradle for *building* JVM projects stays owned by the
# JVM plugins and project wrappers -- but `sdkmanager` is itself a Java program,
# so a headless JRE has to exist in this image for the step below to run at all.
# Without one it exits 1 having printed its "no java command could be found"
# complaint to stdout, which the `>/dev/null` on the --licenses line discards,
# so the build fails with no output whatsoever.
# This installs only the Android SDK manager packages shared by
# Android builds and emulator-backed sessions.
RUN set -eu; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" "${ANDROID_USER_HOME}" "${ANDROID_AVD_HOME}"; \
    cmdline_zip="/tmp/android-commandlinetools.zip"; \
    curl -fsSL -o "${cmdline_zip}" \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip"; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA256}  ${cmdline_zip}" | sha256sum -c -; \
    unzip -q "${cmdline_zip}" -d /tmp/android-cmdline-tools; \
    mv /tmp/android-cmdline-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    rm -f "${cmdline_zip}"; \
    rm -rf /tmp/android-cmdline-tools; \
    yes | "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null; \
    "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" \
      "platform-tools" \
      "emulator" \
      "platforms;${ANDROID_PLATFORM_VERSION}" \
      "build-tools;${ANDROID_BUILD_TOOLS_VERSION}"; \
    chown -R 1000:1000 "${ANDROID_SDK_ROOT}" "${ANDROID_USER_HOME}"

# sccache — transparent remote compiler cache for C/C++ builds .
# Installed as a real binary, then masqueraded onto PATH under the names
# CMake/Make/Meson/Bazel all resolve host compilers by — no per-repo
# .syrus.yml or CMakeLists.txt changes needed. The shim symlinks land in
# /usr/local/bin, which already precedes /usr/bin (where apt puts the real
# gcc/g++/clang/clang++) on this image's default PATH; sccache finds the
# *real* compiler at invocation time by searching PATH with its own
# directory removed, so the shim dir must stay separate from wherever the
# real toolchain lives. Backend config (S3/MinIO bucket, credentials) is
# environment-driven at grader/prepare time — see
# Steps::Prepare::PREP_ENV_FORWARD — and sccache falls back to a local
# per-pod disk cache when SCCACHE_BUCKET is unset, so this is safe to ship
# before the operator provisions a bucket.
ARG SCCACHE_VERSION=0.17.0
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) sccache_arch=x86_64-unknown-linux-musl ;; \
      arm64) sccache_arch=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported architecture for sccache: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    sccache_dir="sccache-v${SCCACHE_VERSION}-${sccache_arch}"; \
    sccache_tarball="${sccache_dir}.tar.gz"; \
    curl -fsSL -o "/tmp/${sccache_tarball}" \
      "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/${sccache_tarball}"; \
    tar -xzf "/tmp/${sccache_tarball}" -C /tmp; \
    install -m 0755 "/tmp/${sccache_dir}/sccache" /usr/local/bin/sccache; \
    rm -rf "/tmp/${sccache_tarball}" "/tmp/${sccache_dir}"; \
    for name in cc c++ gcc g++ clang clang++; do \
      ln -sf /usr/local/bin/syrus-sccache-compiler "/usr/local/bin/${name}"; \
    done

COPY <<'EOF' /usr/local/bin/syrus-sccache-compiler
#!/bin/sh
name="$(basename "$0")"
case "$name" in
  clang|clang++) real="/usr/bin/${name}-18" ;;
  *) real="/usr/bin/$name" ;;
esac
err="$(mktemp)"

if /usr/local/bin/sccache "$real" "$@" 2>"$err"; then
  rm -f "$err"
  exit 0
fi

status=$?
if grep -Eiq 'server startup failed|cache storage failed|connection refused|timed out|temporary' "$err"; then
  cat "$err" >&2
  echo "[syrus-sccache] sccache unavailable; falling back to $real" >&2
  rm -f "$err"
  exec "$real" "$@"
fi

cat "$err" >&2
rm -f "$err"
exit "$status"
EOF

RUN chmod 0755 /usr/local/bin/syrus-sccache-compiler

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

ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:/opt/python-tools/bin:/opt/mise/shims:${PATH}" \
    MISE_DATA_DIR=/opt/mise \
    MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml \
    SYRUS_MISE_GO_VERSION=${MISE_GO_VERSION}

# Headless Chrome + Playwright, for the SyrusBrowser MCP tool set the
# visual_review agent drives against its own in-step preview (127.0.0.1
# only — see SyrusBrowser::LoopbackGuard). Worker-only: the `app` stage
# (web pod) never spawns a browser, so this stays out of that image. This
# must NOT require any change to a target customer repository being cloned
# into the worker — the browser binary lives only here, in Syrus's own
# image. PLAYWRIGHT_BROWSERS_PATH pins the download to a shared,
# world-readable location instead of $HOME/.cache/ms-playwright, since this
# RUN executes as root but the worker container ultimately runs as uid 1000
# (rails). `--with-deps` also apt-installs the system libraries Chromium
# needs (nss, libatk, libgtk, etc.); `@playwright/mcp` is Microsoft's own
# MCP server, bundled as a stdio subprocess rather than hand-rolled —
# SyrusBrowser::McpToolSet spawns it and re-exposes granular tools.
ARG PLAYWRIGHT_VERSION=1.57.0
ARG PLAYWRIGHT_MCP_VERSION=0.0.79
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# Do not use BuildKit apt cache mounts here. Playwright's `install --with-deps`
# drives apt internally, and a full/stale cache mount makes apt fail with
# "No space left on device" before it can refresh package lists.
RUN set -eu; \
    cleanup_apt_cache() { rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; }; \
    cleanup_apt_cache; \
    trap cleanup_apt_cache EXIT; \
    npm install -g "playwright@${PLAYWRIGHT_VERSION}" "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" && \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium && \
    mkdir -p /opt/syrus-browser && \
    ln -s "$(find "${PLAYWRIGHT_BROWSERS_PATH}" -path '*/chrome-linux*/chrome' -type f | sort | tail -n 1)" /opt/syrus-browser/chromium && \
    mkdir -p /opt/google/chrome && \
    ln -s /opt/syrus-browser/chromium /opt/google/chrome/chrome && \
    chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}" && \
    chmod a+rx /opt/syrus-browser/chromium && \
    chmod a+rx /opt/google/chrome/chrome && \
    npm cache clean --force

# ============================================================================
# Worker dev stage — `worker-deps` plus the same rails code + bundle
# the `app` stage gets. Mirrors app's COPY-from-build + GIT_SHA + entry
# wiring; intentionally parallel to `app` so the two diverge only on
# the worker tooling (above) and not on runtime contract.
# ============================================================================
FROM worker-deps AS worker-dev

USER 1000:1000

RUN go version
RUN cd "$(mktemp -d)" && ruby -rmkmf -e 'abort "native compiler smoke check failed" unless try_compile("int main(){return 0;}")'
RUN clang++-18 --version && clang++ --version | grep -q "version 18" && mull-runner-18 --version && mull-runner --version

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --chown=root:root --from=cli-build /usr/local/bin/syrus /usr/local/bin/syrus
RUN /usr/local/bin/syrus --help >/dev/null

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
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 CMD if [ -n "$SYRUS_ROLE" ] && [ "$SYRUS_ROLE" != "web" ]; then exit 0; fi; curl -fsS http://127.0.0.1/readyz >/dev/null || exit 1

# Inherits app's posture (thrust+rails server) by default; the worker
# pod's Deployment overrides command to `bin/jobs` per greenacres#16.
CMD ["./bin/thrust", "./bin/rails", "server"]
