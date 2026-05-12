require "rails_helper"

RSpec.describe "Dockerfile" do
  def dockerfile
    Rails.root.join("Dockerfile").read
  end

  def worker_deps_stage
    dockerfile.match(/FROM base AS worker-deps(?<stage>.*?)FROM worker-deps AS worker-dev/m)[:stage]
  end

  it "installs Poetry as an executable worker tool" do
    stage = worker_deps_stage

    expect(stage).to include("python3 python3-pip python3-venv")
    expect(stage).to include("python3 -m venv /opt/python-tools")
    expect(stage).to include("/opt/python-tools/bin/pip install --no-cache-dir poetry uv")
    expect(stage).to include("ln -s /opt/python-tools/bin/poetry /usr/local/bin/poetry")
    expect(stage).to include("PATH=\"/opt/python-tools/bin:/opt/mise/shims:${PATH}\"")
  end
end
