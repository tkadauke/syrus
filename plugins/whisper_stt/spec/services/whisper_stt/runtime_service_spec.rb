require "rails_helper"

RSpec.describe WhisperStt::RuntimeService do
  around do |example|
    original = ENV.to_h.slice("SYRUS_WHISPER_STT_IMAGE", "SYRUS_VERSION")
    example.run
  ensure
    %w[SYRUS_WHISPER_STT_IMAGE SYRUS_VERSION].each { |key| ENV[key] = original[key] }
  end

  it "registers the plugin as a disabled Plugin Runtime service" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "whisper_stt" }

    expect(manifest).not_to be_nil
    expect(manifest.display_name).to eq("Whisper speech-to-text")
    expect(manifest.default_enabled).to be(false)
    expect(manifest.disableable).to be(true)
    expect(manifest.depends_on).to eq([ "plugin_runtime" ])
    expect(manifest.provides).to eq("plugin_runtime:service" => described_class)
  end

  it "declares a service Plugin Runtime can run" do
    expect(PluginRuntime::Service.implemented_by?(described_class)).to be(true)
    expect(described_class.service_name).to eq("whisper-stt")
    expect(described_class.service_spec).to include(
      internal_port: 8080,
      env: {},
      healthcheck: { path: "/health" }
    )
  end

  it "runs the image from the same release as Syrus" do
    ENV["SYRUS_WHISPER_STT_IMAGE"] = nil
    ENV["SYRUS_VERSION"] = "0.9.2"

    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-whisper-stt:0.9.2")
  end

  it "uses latest for builds without a release version and honours an explicit image" do
    ENV["SYRUS_WHISPER_STT_IMAGE"] = nil
    ENV["SYRUS_VERSION"] = nil
    expect(described_class.service_spec[:image]).to end_with(":latest")

    ENV["SYRUS_WHISPER_STT_IMAGE"] = "ghcr.io/tkadauke/syrus-plugin-whisper-stt:pinned"
    expect(described_class.service_spec[:image]).to eq("ghcr.io/tkadauke/syrus-plugin-whisper-stt:pinned")
  end
end
