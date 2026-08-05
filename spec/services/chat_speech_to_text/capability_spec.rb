require "rails_helper"

RSpec.describe ChatSpeechToText::Capability do
  let(:user) { Factories.user }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_STT_PROVIDER").and_return(nil)
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_EXECUTABLE").and_return(nil)
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_MODEL").and_return(nil)
    allow(ENV).to receive(:[]).with("SYRUS_STT_BACKEND_STREAMING").and_return(nil)
  end

  it "does not offer any dictation mode when the feature is disabled" do
    Feature.where(slug: "chat_speech_to_text").delete_all

    expect(described_class.for(user: user).as_json).to eq(
      enabled: false,
      modes: {
        backend_streaming: { available: false },
        backend_batch: { available: false },
        browser: { available: false }
      }
    )
  end

  it "offers browser fallback without assuming a backend dependency" do
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)

    expect(described_class.for(user: user).as_json).to eq(
      enabled: true,
      modes: {
        backend_streaming: { available: false },
        backend_batch: { available: false },
        browser: { available: true }
      }
    )
  end

  it "offers configured whisper.cpp batch transcription without shelling out" do
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
    allow(ENV).to receive(:[]).with("SYRUS_STT_PROVIDER").and_return("whisper_cpp")
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_EXECUTABLE").and_return("/usr/local/bin/whisper-cli")
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_MODEL").and_return("/models/ggml-base.en.bin")

    expect(Kernel).not_to receive(:system)
    expect(described_class.for(user: user).as_json.dig(:modes, :backend_batch, :available)).to eq(true)
  end
end
