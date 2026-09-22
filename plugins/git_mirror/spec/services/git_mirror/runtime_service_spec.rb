require "rails_helper"

RSpec.describe GitMirror::RuntimeService do
  around do |example|
    original = ENV.to_h.slice("SYRUS_GIT_MIRROR_TOKEN", "SYRUS_GIT_MIRROR_IMAGE", "SYRUS_VERSION")
    example.run
  ensure
    %w[SYRUS_GIT_MIRROR_TOKEN SYRUS_GIT_MIRROR_IMAGE SYRUS_VERSION].each { |key| ENV[key] = original[key] }
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

  it "runs the image from the same release as Syrus" do
    ENV["SYRUS_VERSION"] = "0.9.2"

    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-git-mirror:0.9.2")
  end

  it "uses latest for builds without a release version and honours an explicit image" do
    ENV["SYRUS_VERSION"] = nil
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
