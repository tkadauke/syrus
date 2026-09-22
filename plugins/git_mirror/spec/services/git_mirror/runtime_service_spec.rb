require "rails_helper"

RSpec.describe GitMirror::RuntimeService do
  around do |example|
    original = ENV.to_h.slice("SYRUS_GIT_MIRROR_TOKEN", "SYRUS_GIT_MIRROR_IMAGE", "GIT_SHA")
    example.run
  ensure
    %w[SYRUS_GIT_MIRROR_TOKEN SYRUS_GIT_MIRROR_IMAGE GIT_SHA].each { |key| ENV[key] = original[key] }
  end

  it "declares a service Plugin Runtime can run" do
    expect(PluginRuntime::Service.implemented_by?(described_class)).to be(true)
    expect(described_class.service_name).to eq("git-mirror")
    expect(described_class.service_spec).to include(
      internal_port: 8080,
      volumes: [ { name: "data", mount_path: "/data" } ],
      healthcheck: { path: "/healthz" }
    )
  end

  it "runs the image built from the same commit as Syrus" do
    ENV["GIT_SHA"] = "abc1234"

    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-git-mirror:abc1234")
  end

  it "uses latest for development builds and honours an explicit image" do
    ENV["GIT_SHA"] = nil
    expect(described_class.service_spec[:image]).to end_with(":latest")

    ENV["SYRUS_GIT_MIRROR_IMAGE"] = "ghcr.io/tkadauke/syrus-plugin-git-mirror:pinned"
    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-git-mirror:pinned")
  end

  it "hands the service a stable token that is long enough and not stored anywhere" do
    ENV["SYRUS_GIT_MIRROR_TOKEN"] = nil
    token = described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]

    expect(token).to match(/\A\h{64}\z/)
    expect(described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]).to eq(token)

    ENV["SYRUS_GIT_MIRROR_TOKEN"] = "operator-set-token-for-kubernetes-0123456789"
    expect(described_class.service_spec[:env]["GIT_MIRROR_TOKEN"]).to eq("operator-set-token-for-kubernetes-0123456789")
  end
end
