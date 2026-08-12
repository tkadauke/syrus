require "rails_helper"

RSpec.describe ChatSpeechToText::Providers do
  def stub_env(overrides)
    allow(ENV).to receive(:[]).and_call_original
    overrides.each do |key, value|
      allow(ENV).to receive(:[]).with(key).and_return(value)
    end
  end

  describe ".configured" do
    it "defaults to the bundled whisper.cpp provider when env vars are unset and the baked-in files exist" do
      stub_env(
        "SYRUS_STT_PROVIDER" => nil,
        "SYRUS_STT_WHISPER_CPP_EXECUTABLE" => nil,
        "SYRUS_STT_WHISPER_CPP_MODEL" => nil
      )
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_EXECUTABLE_PATH).and_return(true)
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_MODEL_PATH).and_return(true)

      provider = described_class.configured

      expect(provider).to be_a(ChatSpeechToText::Providers::WhisperCpp)
    end

    it "returns nil when env vars are unset and the baked-in files are absent" do
      stub_env(
        "SYRUS_STT_PROVIDER" => nil,
        "SYRUS_STT_WHISPER_CPP_EXECUTABLE" => nil,
        "SYRUS_STT_WHISPER_CPP_MODEL" => nil
      )
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_EXECUTABLE_PATH).and_return(false)
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_MODEL_PATH).and_return(false)

      expect(described_class.configured).to be_nil
    end

    it "prefers explicit env vars over the baked-in defaults even when both exist" do
      stub_env(
        "SYRUS_STT_PROVIDER" => "whisper_cpp",
        "SYRUS_STT_WHISPER_CPP_EXECUTABLE" => "/custom/whisper-cli",
        "SYRUS_STT_WHISPER_CPP_MODEL" => "/custom/model.bin"
      )
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_EXECUTABLE_PATH).and_return(true)
      allow(File).to receive(:exist?).with(ChatSpeechToText::Providers::WhisperCpp::BUNDLED_MODEL_PATH).and_return(true)

      provider = described_class.configured

      expect(provider.instance_variable_get(:@executable)).to eq("/custom/whisper-cli")
      expect(provider.instance_variable_get(:@model)).to eq("/custom/model.bin")
    end
  end
end
