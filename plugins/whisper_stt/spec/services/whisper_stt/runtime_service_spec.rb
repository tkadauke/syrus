require "rails_helper"

RSpec.describe WhisperStt::RuntimeService do
  around do |example|
    keys = %w[SYRUS_WHISPER_STT_IMAGE SYRUS_VERSION SYRUS_WHISPER_STT_MEMORY_LIMIT_BYTES]
    original = ENV.to_h.slice(*keys)
    example.run
  ensure
    keys.each { |key| ENV[key] = original[key] }
  end

  it "registers the plugin as a disabled Plugin Runtime service" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "whisper_stt" }

    expect(manifest).not_to be_nil
    expect(manifest.display_name).to eq("Whisper speech-to-text")
    expect(manifest.default_enabled).to be(false)
    expect(manifest.disableable).to be(true)
    expect(manifest.depends_on).to eq([ "plugin_runtime" ])
    expect(manifest.provides).to eq(
      "plugin_runtime:service" => described_class,
      speech_to_text_provider: WhisperStt::Provider
    )
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

  # Uncapped, the kernel resolves memory pressure host-wide and the victim is
  # whichever process looks worst -- in practice the Docker daemon, which takes
  # every container down rather than just the one that overran.
  it "caps the daemon's memory and lets a larger model raise the cap" do
    ENV["SYRUS_WHISPER_STT_MEMORY_LIMIT_BYTES"] = nil
    expect(described_class.service_spec[:memory_limit_bytes]).to eq(2 * 1024 * 1024 * 1024)

    ENV["SYRUS_WHISPER_STT_MEMORY_LIMIT_BYTES"] = "6442450944"
    expect(described_class.service_spec[:memory_limit_bytes]).to eq(6_442_450_944)

    # A junk or zero override must not silently uncap the container.
    ENV["SYRUS_WHISPER_STT_MEMORY_LIMIT_BYTES"] = "not-a-number"
    expect(described_class.service_spec[:memory_limit_bytes]).to eq(2 * 1024 * 1024 * 1024)
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
