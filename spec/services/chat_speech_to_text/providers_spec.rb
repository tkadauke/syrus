require "rails_helper"

RSpec.describe ChatSpeechToText::Providers do
  def stub_env(overrides)
    allow(ENV).to receive(:[]).and_call_original
    overrides.each do |key, value|
      allow(ENV).to receive(:[]).with(key).and_return(value)
    end
  end

  describe ".configured" do
    before do
      stub_const("TestSpeechToTextProvider", Class.new(ChatSpeechToText::Providers::Base) do
        include Syrus::Plugin::SpeechToTextProvider

        class << self
          attr_accessor :available, :built_users
        end

        self.available = true
        self.built_users = []

        def self.provider_key = "test_stt"
        def self.display_name = "Test STT"
        def self.available? = available

        def self.build(user:)
          built_users << user
          new
        end

        def batch? = true
      end)

      stub_const("PinnedSpeechToTextProvider", Class.new(ChatSpeechToText::Providers::Base) do
        include Syrus::Plugin::SpeechToTextProvider

        def self.provider_key = "pinned_stt"
        def self.display_name = "Pinned STT"
        def self.available? = true
        def self.build(user:) = new

        def streaming? = true
      end)
    end

    it "resolves the first available provider from the plugin registry" do
      user = Factories.user
      stub_env("SYRUS_STT_PROVIDER" => nil)
      Syrus::PluginRegistry.register(
        name: "test-speech-to-text",
        version: "1.0.0",
        provides: { speech_to_text_provider: TestSpeechToTextProvider }
      )

      provider = described_class.configured(user: user)

      expect(provider).to be_a(TestSpeechToTextProvider)
      expect(TestSpeechToTextProvider.built_users).to eq([ user ])
    end

    it "returns nil when nothing is registered" do
      stub_env("SYRUS_STT_PROVIDER" => nil)

      expect(described_class.configured).to be_nil
    end

    it "returns nil when registered providers are unavailable" do
      stub_env("SYRUS_STT_PROVIDER" => nil)
      TestSpeechToTextProvider.available = false
      Syrus::PluginRegistry.register(
        name: "test-speech-to-text",
        version: "1.0.0",
        provides: { speech_to_text_provider: TestSpeechToTextProvider }
      )

      expect(described_class.configured).to be_nil
    end

    it "filters candidates by the optional env pin" do
      stub_env("SYRUS_STT_PROVIDER" => "pinned_stt")
      Syrus::PluginRegistry.register(
        name: "test-speech-to-text",
        version: "1.0.0",
        provides: { speech_to_text_provider: [ TestSpeechToTextProvider, PinnedSpeechToTextProvider ] }
      )

      provider = described_class.configured

      expect(provider).to be_a(PinnedSpeechToTextProvider)
    end

    it "falls through when an available provider cannot build for the user" do
      stub_env("SYRUS_STT_PROVIDER" => nil)
      allow(TestSpeechToTextProvider).to receive(:build).and_return(nil)
      Syrus::PluginRegistry.register(
        name: "test-speech-to-text",
        version: "1.0.0",
        provides: { speech_to_text_provider: [ TestSpeechToTextProvider, PinnedSpeechToTextProvider ] }
      )

      provider = described_class.configured

      expect(provider).to be_a(PinnedSpeechToTextProvider)
    end

    it "returns nil when the env pin does not match any available provider" do
      stub_env("SYRUS_STT_PROVIDER" => "missing_stt")
      Syrus::PluginRegistry.register(
        name: "test-speech-to-text",
        version: "1.0.0",
        provides: { speech_to_text_provider: TestSpeechToTextProvider }
      )

      expect(described_class.configured).to be_nil
    end
  end
end
