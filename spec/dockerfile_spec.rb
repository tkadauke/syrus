require "rails_helper"

RSpec.describe "Dockerfile" do
  def dockerfile
    Rails.root.join("Dockerfile").read
  end

  def worker_deps_stage
    dockerfile.match(/FROM base AS worker-deps(?<stage>.*?)FROM worker-deps AS worker-dev/m)[:stage]
  end

  it "creates the data root with rails ownership before runtime stages drop privileges" do
    user_setup = dockerfile.match(/RUN groupadd --system --gid 1000 rails(?<setup>.*?)FROM base AS build/m)[:setup]
    app_stage = dockerfile.match(/FROM base AS app(?<stage>.*?)FROM docker\.io\/library\/debian:bookworm-slim AS runtime-cache/m)[:stage]
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
    expect(stage).to include("PATH=\"/opt/python-tools/bin:/opt/mise/shims:${PATH}\"")
  end
end
