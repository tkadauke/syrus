require "rails_helper"

RSpec.describe SyrusBrowser::Configuration do
  describe ".endpoint" do
    it "delegates to PluginRuntime::Services for the browser service name" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("browser").and_return("http://browser-service:8080")

      expect(described_class.endpoint).to eq("http://browser-service:8080")
    end

    it "answers nil when Plugin Runtime has no browser service registered" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("browser").and_return(nil)

      expect(described_class.endpoint).to be_nil
    end

    it "answers nil instead of raising when PluginRuntime::Services cannot be resolved at all" do
      # Browser only optionally_depends_on plugin_runtime, so this has to
      # survive the plugin being physically absent, not just disabled --
      # exactly what a bare `PluginRuntime::Services` constant reference
      # would not survive. hide_const simulates that absence without actually
      # unloading the gem.
      hide_const("PluginRuntime::Services")

      expect { described_class.endpoint }.not_to raise_error
      expect(described_class.endpoint).to be_nil
    end
  end

  describe ".image" do
    around do |example|
      original = ENV.to_h.slice("SYRUS_BROWSER_IMAGE", "SYRUS_VERSION")
      example.run
    ensure
      %w[SYRUS_BROWSER_IMAGE SYRUS_VERSION].each { |key| ENV[key] = original[key] }
    end

    it "runs the image from the same release as Syrus" do
      ENV["SYRUS_BROWSER_IMAGE"] = nil
      ENV["SYRUS_VERSION"] = "0.9.2"

      expect(described_class.image).to eq("ghcr.io/tkadauke/syrus-plugin-browser:0.9.2")
    end

    it "uses latest for builds without a release version and honours an explicit image" do
      ENV["SYRUS_BROWSER_IMAGE"] = nil
      ENV["SYRUS_VERSION"] = nil
      expect(described_class.image).to end_with(":latest")

      ENV["SYRUS_BROWSER_IMAGE"] = "ghcr.io/tkadauke/syrus-plugin-browser:pinned"
      expect(described_class.image).to eq("ghcr.io/tkadauke/syrus-plugin-browser:pinned")
    end
  end
end
