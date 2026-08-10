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

  it "installs Poetry as an executable worker tool" do
    stage = worker_deps_stage

    expect(stage).to include("ARG POETRY_VERSION=")
    expect(stage).to include("ARG UV_VERSION=")
    expect(stage).to include("python3 python3-pip python3-venv")
    expect(stage).to include("python3 -m venv /opt/python-tools")
    expect(stage).to include("poetry==${POETRY_VERSION}")
    expect(stage).to include("uv==${UV_VERSION}")
    expect(stage).to include("ln -s /opt/python-tools/bin/poetry /usr/local/bin/poetry")
    expect(stage).to include("PATH=\"/opt/mise/installs/go/${MISE_GO_VERSION}/bin:/opt/python-tools/bin:/opt/mise/shims:${PATH}\"")
  end

  it "pins a Codex CLI version with current model metadata support" do
    expect(dockerfile).to include("ARG CODEX_CLI_VERSION=0.147.0")
    expect(dockerfile).to include("@openai/codex@${CODEX_CLI_VERSION}")
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
    expect(worker_deps).to include("ARG MISE_GO_VERSION=\"1.26.5\"")
    expect(worker_deps).to include("PATH=\"/opt/mise/installs/go/${MISE_GO_VERSION}/bin:/opt/python-tools/bin:/opt/mise/shims:${PATH}\"")
    expect(worker_dev).to include("RUN go version")
  end
end
