require "rails_helper"

RSpec.describe SyrusBrowser::RuntimeService do
  around do |example|
    original = ENV.to_h.slice("SYRUS_BROWSER_IMAGE", "SYRUS_VERSION")
    example.run
  ensure
    %w[SYRUS_BROWSER_IMAGE SYRUS_VERSION].each { |key| ENV[key] = original[key] }
  end

  it "declares a service Plugin Runtime can run" do
    expect(PluginRuntime::Service.implemented_by?(described_class)).to be(true)
    expect(described_class.service_name).to eq("browser")
    expect(described_class.service_spec).to eq(
      image: described_class.service_spec[:image],
      internal_port: 8080,
      healthcheck: { path: "/healthz" }
    )
  end

  it "runs the image from the same release as Syrus" do
    ENV["SYRUS_BROWSER_IMAGE"] = nil
    ENV["SYRUS_VERSION"] = "0.9.2"

    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-browser:0.9.2")
  end

  it "uses latest for builds without a release version and honours an explicit image" do
    ENV["SYRUS_BROWSER_IMAGE"] = nil
    ENV["SYRUS_VERSION"] = nil
    expect(described_class.service_spec[:image]).to end_with(":latest")

    ENV["SYRUS_BROWSER_IMAGE"] = "ghcr.io/tkadauke/syrus-plugin-browser:pinned"
    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-browser:pinned")
  end

  it "declares no volumes or env: the service is stateless and holds no secret to share" do
    expect(described_class.service_spec).not_to have_key(:volumes)
    expect(described_class.service_spec).not_to have_key(:env)
  end
end
