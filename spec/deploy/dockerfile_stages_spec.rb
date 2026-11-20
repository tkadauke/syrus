# frozen_string_literal: true

require_relative "deploy_helper"

RSpec.describe Deploy::DockerfileStages do
  let(:dockerfile) do
    <<~DOCKERFILE
      ARG RUBY_VERSION=3.4
      FROM ruby:${RUBY_VERSION} AS base
      RUN apt-get install -y \\
            curl git
      FROM base AS build
      COPY . .
      FROM debian AS runtime
      RUN echo runtime
      FROM base AS tools
      # comments never matter
      COPY --from=runtime /opt /opt
      COPY <<'EOF2' /usr/local/bin/helper
      echo helper
      EOF2
      FROM tools AS final
      COPY --from=build /rails /rails
    DOCKERFILE
  end

  def stages(text) = described_class.new(text)

  it "follows FROM and COPY --from to the stages a target is built from" do
    expect(stages(dockerfile).closure("tools").map(&:name)).to eq(%w[base runtime tools])
    expect(stages(dockerfile).closure("final").map(&:name)).to eq(%w[base build runtime tools final])
  end

  it "ignores changes to stages the target never reaches, and to comments" do
    original = stages(dockerfile).digest("tools")

    expect(stages(dockerfile.sub("COPY . .", "COPY app/ ./app/")).digest("tools")).to eq(original)
    expect(stages(dockerfile.sub("# comments never matter", "# reworded")).digest("tools")).to eq(original)
    expect(stages(dockerfile.sub("            curl git", "            curl  git")).digest("tools")).to eq(original)
  end

  it "changes when the target's own inputs, a dependency, a heredoc, or a global ARG change" do
    original = stages(dockerfile).digest("tools")

    expect(stages(dockerfile.sub("curl git", "curl git jq")).digest("tools")).not_to eq(original)
    expect(stages(dockerfile.sub("echo runtime", "echo other")).digest("tools")).not_to eq(original)
    expect(stages(dockerfile.sub("echo helper", "echo changed")).digest("tools")).not_to eq(original)
    expect(stages(dockerfile.sub("RUBY_VERSION=3.4", "RUBY_VERSION=3.5")).digest("tools")).not_to eq(original)
  end

  it "keeps the real worker toolchain separate from the application code" do
    real = described_class.from_file(File.join(DeploySpec::ROOT, "Dockerfile"))

    expect(real.closure("worker-deps").map(&:name)).not_to include("build", "cli-build", "app")
  end

  it "refuses an unknown stage" do
    expect { stages(dockerfile).closure("nope") }.to raise_error(ArgumentError, /unknown Dockerfile stage/)
  end
end
