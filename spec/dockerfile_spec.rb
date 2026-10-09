require "rails_helper"

RSpec.describe "Dockerfile" do
  def dockerfile
    Rails.root.join("Dockerfile").read
  end

  def worker_deps_stage
    dockerfile.match(/FROM base AS worker-deps(?<stage>.*?)FROM worker-deps AS worker-dev/m)[:stage]
  end

  def stage(name, until_stage = nil)
    pattern =
      if until_stage
        /FROM .* AS #{Regexp.escape(name)}(?<stage>.*?)(?=FROM #{Regexp.escape(until_stage)})/m
      else
        /FROM .* AS #{Regexp.escape(name)}(?<stage>.*?)(?=FROM )/m
      end
    dockerfile.match(pattern)[:stage]
  end

  it "creates the data root with rails ownership before runtime stages drop privileges" do
    user_setup = dockerfile.match(/RUN groupadd --system --gid 1000 rails(?<setup>.*?)FROM base AS build/m)[:setup]
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]
    worker_stage = dockerfile.match(/FROM worker-deps AS worker-dev(?<stage>.*)\z/m)[:stage]

    expect(user_setup).to include("mkdir -p /home/rails/.syrus")
    expect(user_setup).to include("chown 1000:1000 /home/rails/.syrus")
    expect(app_stage.index("USER 1000:1000")).to be < app_stage.index("ENTRYPOINT")
    expect(worker_stage.index("USER 1000:1000")).to be < worker_stage.index("ENTRYPOINT")
  end

  it "uses a Debian base that has a populated Mull package suite" do
    expect(dockerfile).to include("FROM docker.io/library/ruby:$RUBY_VERSION-slim-trixie AS base")
  end

  it "probes readiness only for web/default image roles" do
    healthchecks = dockerfile.scan(/^HEALTHCHECK .+$/)

    expect(healthchecks.size).to eq(2)
    healthchecks.each do |healthcheck|
      expect(healthcheck).to include('curl -fsS http://127.0.0.1/readyz')
      expect(healthcheck).to include('[ -n "$SYRUS_ROLE" ] && [ "$SYRUS_ROLE" != "web" ]')
    end
  end

  it "installs Poetry as an executable worker tool" do
    stage = worker_deps_stage

    expect(stage).to include("ARG POETRY_VERSION=")
    expect(stage).to include("ARG UV_VERSION=")
    expect(stage).to include("python3 python3-pip python3-venv")
    expect(stage).to include("python3 -m venv /opt/python-tools")
    expect(stage).to include("poetry==${POETRY_VERSION}")
    expect(stage).to include("uv==${UV_VERSION}")
    expect(stage).to include("ln -s /opt/python-tools/bin/poetry /usr/local/bin/poetry")
    expect(stage).to include("/opt/python-tools/bin:/opt/mise/shims:${PATH}")
  end

  it "pins a Codex CLI version with current model metadata support" do
    expect(dockerfile).to include("ARG CODEX_CLI_VERSION=0.160.0")
    expect(dockerfile).to include("@openai/codex@${CODEX_CLI_VERSION}")
  end

  it "installs Muse Code without requiring build-time credentials" do
    expect(dockerfile).to include("ARG MUSE_LAUNCHER_URL=https://api.meta.ai/muse-launcher.sh")
    expect(dockerfile).to include('curl -fsSL "${MUSE_LAUNCHER_URL}" -o /opt/muse/bin/muse')
    expect(dockerfile).to include("MUSE_LAUNCHER_INSTALL=1 /opt/muse/bin/muse")
    expect(dockerfile).to include("MUSE_NO_AUTO_UPDATE=1 /opt/muse/bin/muse --version")
    expect(dockerfile).to include('PATH="/opt/muse/bin:${PATH}"')
    expect(dockerfile).to include('MUSE_NO_AUTO_UPDATE="1"')
    expect(dockerfile).not_to include("muse login")
    expect(dockerfile).not_to include("muse auth")
  end

  it "installs a pinned Antigravity CLI binary into the base image" do
    expect(dockerfile).to include("ARG ANTIGRAVITY_CLI_VERSION=1.2.1")
    expect(dockerfile).to include("ARG ANTIGRAVITY_CLI_BUILD=5123043593420800")
    expect(dockerfile).to include("ARG ANTIGRAVITY_CLI_LINUX_AMD64_SHA512=0629fe69e6949b35707935ef35da016074ea29a5d989a05f740713e0a9e927bf52ff1eada0204d3338779a469c938b6b7c5c44de2d296e5e8db255d26568de38")
    expect(dockerfile).to include("ARG ANTIGRAVITY_CLI_LINUX_ARM64_SHA512=f6dd6057a82dcbc4ab0878d99c4b84cfc45c3e2f12647eaf435322ecdd18d0190620bca943185f542431b93f34f5ea19cf84e8fdb902e64529e110bfa0a5a46f")
    expect(dockerfile).to include("amd64) antigravity_dir=x64; antigravity_arch=x64;")
    expect(dockerfile).to include("arm64) antigravity_dir=arm; antigravity_arch=arm64;")
    expect(dockerfile).to include("linux-${antigravity_dir}/cli_linux_${antigravity_arch}.tar.gz")
    expect(dockerfile).to include("sha512sum -c -")
    expect(dockerfile).to include("install -m 0755 /tmp/antigravity /usr/local/bin/agy")
  end

  it "builds and installs the Syrus CLI into app and worker runtime images" do
    cli_stage = stage("cli-build", "base AS app")
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]
    worker_stage = dockerfile.match(/FROM worker-deps AS worker-dev(?<stage>.*)\z/m)[:stage]
    plugin_cli_modules = Rails.root.join("go.work").read.scan(%r{use \./(plugins/[^/]+/cli)}).flatten

    expect(dockerfile).to include("FROM docker.io/library/golang:1.26.5-bookworm AS cli-build")
    expect(cli_stage).to include("COPY go.work go.work.sum ./")
    expect(cli_stage).to include("COPY cli/go.mod cli/go.sum ./cli/")
    expect(cli_stage).to include("cd cli && GOWORK=off go mod download")
    expect(cli_stage).to include('env GOWORK=off CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch"')
    expect(cli_stage).to include('go build -trimpath -ldflags="-s -w" -o /usr/local/bin/syrus .')

    plugin_cli_modules.each do |module_path|
      expect(cli_stage).to include("COPY #{module_path}/go.mod ./#{module_path}/")
      expect(cli_stage).to include("COPY #{module_path}/ ./#{module_path}/")
    end

    expect(app_stage).to include("COPY --chown=root:root --from=cli-build /usr/local/bin/syrus /usr/local/bin/syrus")
    expect(app_stage).to include("RUN /usr/local/bin/syrus --help >/dev/null")
    expect(worker_stage).to include("COPY --chown=root:root --from=cli-build /usr/local/bin/syrus /usr/local/bin/syrus")
    expect(worker_stage).to include("RUN /usr/local/bin/syrus --help >/dev/null")
  end

  it "keeps Ruby runtimes in their own exact-pinned cache stage, installed prebuilt" do
    ruby_stage = stage("runtime-ruby-cache")
    node_stage = stage("runtime-node-cache")
    python_stage = stage("runtime-python-cache")
    go_stage = stage("runtime-go-cache")
    assembly_stage = stage("runtime-cache", "base AS worker-deps")

    expect(ruby_stage).to include('ARG MISE_RUBIES="3.4.10 3.3.11"')
    expect(ruby_stage).to include("mise install $(for v in $MISE_RUBIES")
    # Prebuilt Ruby binaries (glibc-2.36-compatible), not a ~13-min source
    # compile. The env override must sit on the install RUN itself.
    expect(ruby_stage).to match(/MISE_RUBY_COMPILE=0 \S*mise install \$\(for v in \$MISE_RUBIES/)
    expect(ruby_stage).not_to include("MISE_NODES")
    expect(ruby_stage).not_to include("MISE_PYTHONS")
    expect(ruby_stage).not_to include("MISE_GO_VERSION")

    expect(node_stage).to include("ARG MISE_NODES=")
    expect(python_stage).to include("ARG MISE_PYTHONS=")
    expect(go_stage).to include("ARG MISE_GO_VERSION=")
    expect(assembly_stage).to include("COPY --from=runtime-ruby-cache /opt/mise/ /opt/mise/")
    expect(assembly_stage).to include("COPY --from=runtime-go-cache /opt/mise/ /opt/mise/")
    expect(assembly_stage).to include("/usr/local/bin/mise reshim")
  end

  it "preinstalls Go for the worker image" do
    runtime_stage = stage("runtime-go-cache")
    worker_deps = worker_deps_stage
    worker_dev = dockerfile.match(/FROM worker-deps AS worker-dev(?<stage>.*)\z/m)[:stage]

    expect(runtime_stage).to include("ARG MISE_GO_VERSION=\"1.26.5\"")
    expect(runtime_stage).to include("/usr/local/bin/mise install go@$MISE_GO_VERSION")
    expect(runtime_stage).to include("/usr/local/bin/mise use --global go@$MISE_GO_VERSION")
    expect(runtime_stage).to include("/usr/local/bin/mise reshim go")
    expect(worker_deps).to include("ARG MISE_GO_VERSION=\"1.26.5\"")
    expect(worker_deps).to include("/opt/python-tools/bin:/opt/mise/shims:${PATH}")
    expect(worker_deps).to include("MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml")
    expect(worker_deps).to include("SYRUS_MISE_GO_VERSION=${MISE_GO_VERSION}")
    expect(worker_dev).to include("RUN go version")
  end

  it "installs version-matched Mull mutation testing tools in the worker image" do
    stage = worker_deps_stage
    worker_dev = dockerfile.match(/FROM worker-deps AS worker-dev(?<stage>.*)\z/m)[:stage]
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]

    expect(stage).to include("ARG MULL_LLVM_VERSION=18")
    expect(stage).to include("mull-project-mull-stable-archive-keyring.gpg")
    expect(stage).to include("mull-project/mull-stable/deb/${ID} ${VERSION_CODENAME} main")
    expect(stage).to include("clang-${MULL_LLVM_VERSION}")
    expect(stage).to include("mull-${MULL_LLVM_VERSION}")
    expect(stage).to include('ln -sf "/usr/bin/mull-runner-${MULL_LLVM_VERSION}" /usr/local/bin/mull-runner')
    expect(stage).to include('clang|clang++) real="/usr/bin/${name}-18"')
    expect(worker_dev).to include('RUN clang++-18 --version && clang++ --version | grep -q "version 18" && mull-runner-18 --version && mull-runner --version')

    expect(app_stage).not_to include("mull-runner")
    expect(app_stage).not_to include("mull-project")
  end

  it "installs a pinned Android SDK baseline only in the worker image" do
    stage = worker_deps_stage
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]

    expect(stage).to include("ARG ANDROID_CMDLINE_TOOLS_VERSION=15859902")
    expect(stage).to include("ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583")
    expect(stage).to include("ARG ANDROID_PLATFORM_VERSION=android-36")
    expect(stage).to include("ARG ANDROID_BUILD_TOOLS_VERSION=36.0.0")
    expect(stage).to include("ANDROID_SDK_ROOT=/opt/android-sdk")
    expect(stage).to include("ANDROID_HOME=/opt/android-sdk")
    expect(stage).to include("wget unzip openssh-client")
    expect(stage).to include("commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip")
    expect(stage).to include('echo "${ANDROID_CMDLINE_TOOLS_SHA256}  ${cmdline_zip}" | sha256sum -c -')
    expect(stage).to include('mv /tmp/android-cmdline-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"')
    expect(stage).to include('yes | "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" --licenses')
    expect(stage).to include('"platform-tools"')
    expect(stage).to include('"emulator"')
    expect(stage).to include('"platforms;${ANDROID_PLATFORM_VERSION}"')
    expect(stage).to include('"build-tools;${ANDROID_BUILD_TOOLS_VERSION}"')
    expect(stage).to include('${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator')

    expect(app_stage).not_to include("ANDROID_SDK_ROOT")
    expect(app_stage).not_to include("sdkmanager")
  end

  it "fails worker image builds when native compilation is unavailable as the rails user" do
    worker_dev = dockerfile.match(/FROM worker-deps AS worker-dev(?<stage>.*)\z/m)[:stage]

    expect(worker_dev.index("USER 1000:1000")).to be < worker_dev.index("try_compile")
    expect(worker_dev).to include(%q{cd "$(mktemp -d)" && ruby -rmkmf -e 'abort "native compiler smoke check failed" unless try_compile("int main(){return 0;}")'})
  end

  it "installs headless Chromium via Playwright, only in the worker image" do
    stage = worker_deps_stage
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]

    expect(stage).to include("ARG PLAYWRIGHT_VERSION=")
    expect(stage).to include("ARG PLAYWRIGHT_MCP_VERSION=")
    expect(stage).to include('ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright')
    expect(stage).to include('npm install -g "playwright@${PLAYWRIGHT_VERSION}" "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"')
    expect(stage).to include('npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium')
    expect(stage).to include('chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"')

    # The `app` stage is the web pod image — it never spawns a browser, so
    # Chromium and Playwright must not leak into it.
    expect(app_stage).not_to include("playwright")
    expect(app_stage).not_to include("PLAYWRIGHT_BROWSERS_PATH")
  end

  it "keeps apt archives on BuildKit cache mounts to avoid layer space exhaustion" do
    dockerfile.scan(/RUN(?<body>.*?apt-get install.*?)(?=\n\n|FROM|\z)/m).flatten.each do |body|
      expect(body).to include("--mount=type=cache,target=/var/cache/apt,sharing=locked")
      expect(body).to include("--mount=type=cache,target=/var/lib/apt/lists,sharing=locked")
      expect(body).to include("rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*")
    end
  end

  it "installs sccache and masquerades it as the C/C++ compiler toolchain, only in the worker image" do
    stage = worker_deps_stage
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-base/m)[:stage]

    expect(stage).to include("ARG SCCACHE_VERSION=")
    expect(stage).to include('"https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/${sccache_tarball}"')
    expect(stage).to include("amd64) sccache_arch=x86_64-unknown-linux-musl")
    expect(stage).to include("arm64) sccache_arch=aarch64-unknown-linux-musl")
    expect(stage).to include("install -m 0755 \"/tmp/${sccache_dir}/sccache\" /usr/local/bin/sccache")

    expect(stage).to include("COPY <<'EOF' /usr/local/bin/syrus-sccache-compiler")
    expect(stage).to include('exec "$real" "$@"')
    expect(stage).to include("sccache unavailable; falling back")
    expect(stage).to include("for name in cc c++ gcc g++ clang clang++; do")
    expect(stage).to include('ln -sf /usr/local/bin/syrus-sccache-compiler "/usr/local/bin/${name}"')

    # The `app` stage is the web pod image — it never compiles C/C++, so the
    # compiler cache has no reason to ship there.
    expect(app_stage).not_to include("sccache")
  end

  it "does not install the tailscale package in the worker image" do
    # Regression: the worker-deps stage used to apt-get install the
    # tailscale/tailscaled binaries so the connectivity plugin could spawn
    # tailscaled directly inside the worker. That daemon now runs in its own
    # privileged container started by Plugin Runtime (see
    # docs/plans/tailscale-privileged-service-lane.md); the worker image has
    # no remaining reason to carry the Tailscale apt source, keyring, or
    # package.
    expect(dockerfile).not_to include("pkgs.tailscale.com")
    expect(dockerfile).not_to include("tailscale-archive-keyring")
    expect(dockerfile).not_to include("apt-get install --no-install-recommends -y tailscale")
  end

  it "does not bundle a speech-to-text subprocess backend in the core image" do
    deleted_stage = "whisper" + "-build"
    deleted_install_path = File.join("/opt", "whisper" + ".cpp")
    deleted_skip_arg = "SYRUS_SKIP_" + "WHISPER_BUILD"

    expect(dockerfile).not_to include(" AS #{deleted_stage}")
    expect(dockerfile).not_to include(deleted_install_path)
    expect(dockerfile).not_to include(deleted_skip_arg)
  end

  it "seeds /opt/mise from /opt/mise-seed on first boot via the entrypoint" do
    worker_deps = worker_deps_stage
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    expect(worker_deps).to include("COPY --from=runtime-cache /opt/mise /opt/mise-seed")
    expect(worker_deps).to include("COPY --from=runtime-cache /opt/mise /opt/mise")
    expect(worker_deps).to include("chown -R 1000:1000 /opt/mise-seed /opt/mise")

    expect(entrypoint).to include("[ -d /opt/mise-seed ]")
    expect(entrypoint).to include("cp -rn /opt/mise-seed/. /opt/mise/")
    expect(entrypoint).to include("mise reshim")
    expect(entrypoint).to include("/opt/mise/installs/go/${SYRUS_MISE_GO_VERSION}")
    expect(entrypoint).to include("mise use --global \"go@${SYRUS_MISE_GO_VERSION}\"")
  end
end
