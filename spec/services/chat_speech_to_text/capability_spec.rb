require "rails_helper"

RSpec.describe ChatSpeechToText::Capability do
  let(:user) { Factories.user }

  before do
    stub_no_chat_speech_to_text_backend!
  end

  it "does not offer any dictation mode when the feature is disabled" do
    Feature.where(slug: "chat_speech_to_text").delete_all

    expect(described_class.for(user: user).as_json).to eq(
      enabled: false,
      backend: {
        configured: false,
        unavailable_reason: "feature_disabled"
      },
      modes: {
        backend_streaming: { available: false, unavailable_reason: "feature_disabled" },
        backend_batch: { available: false, unavailable_reason: "feature_disabled" },
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
      backend: {
        configured: false,
        unavailable_reason: "provider_unset"
      },
      modes: {
        backend_streaming: { available: false, unavailable_reason: "provider_unset" },
        backend_batch: { available: false, unavailable_reason: "provider_unset" },
        browser: { available: true }
      }
    )
  end

  it "reports no backend when provider resolution returns nil" do
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(nil)

    capability = described_class.for(user: user)

    expect(capability.backend_available?).to eq(false)
    expect(capability.as_json).to eq(
      enabled: true,
      backend: {
        configured: false,
        unavailable_reason: "provider_unset"
      },
      modes: {
        backend_streaming: { available: false, unavailable_reason: "provider_unset" },
        backend_batch: { available: false, unavailable_reason: "provider_unset" },
        browser: { available: true }
      }
    )
  end

  it "offers configured backend batch transcription without shelling out" do
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
    provider = instance_double(ChatSpeechToText::Providers::Base, batch?: true, streaming?: false)
    allow(ChatSpeechToText::Providers).to receive(:configured).with(user: user).and_return(provider)

    expect(Kernel).not_to receive(:system)
    expect(described_class.for(user: user).as_json.dig(:modes, :backend_batch, :available)).to eq(true)
    expect(described_class.for(user: user).as_json.dig(:modes, :backend_streaming)).to eq(
      available: false,
      unavailable_reason: "provider_streaming_unavailable"
    )
  end
end
