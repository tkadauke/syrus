require "rails_helper"

RSpec.describe WhisperStt::Provider do
  let(:endpoint) { "http://whisper-stt:8080" }

  def audio_file(content = "webm-bytes")
    file = Tempfile.new([ "dictation", ".webm" ])
    file.binmode
    file.write(content)
    file.rewind
    file
  end

  def request(audio: audio_file, content_type: "audio/webm", language: "en", prompt: "project words")
    ChatSpeechToText::Providers::TranscriptionRequest.new(
      audio: audio,
      content_type: content_type,
      language: language,
      prompt: prompt
    )
  end

  def enable_speech_to_text!
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
  end

  def set_whisper_plugin_enabled!(enabled)
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "whisper_stt").update!(enabled: enabled, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  before do
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("whisper-stt").and_return(endpoint)
  end

  describe ".available?" do
    it "is available only while Plugin Runtime has a usable endpoint" do
      expect(described_class.available?).to be(true)

      allow(PluginRuntime::Services).to receive(:endpoint_for).with("whisper-stt").and_return(nil)

      expect(described_class.available?).to be(false)
      expect(described_class.build(user: Factories.user)).to be_nil
    end
  end

  it "posts browser audio to whisper-server and returns a transcription result" do
    stub = stub_request(:post, "#{endpoint}/inference")
      .with do |http_request|
        http_request.headers["Content-Type"].include?("multipart/form-data")
      end
      .to_return(status: 200, body: { text: "ship the fix\n" }.to_json, headers: { "Content-Type" => "application/json" })
    notifications = []
    subscriber = ActiveSupport::Notifications.subscribe("chat_speech_to_text.transcribed") { |event| notifications << event }

    result = described_class.new.transcribe_batch(request)

    expect(result).to have_attributes(text: "ship the fix", segments: [], provider: "whisper_stt", confidence: nil)
    expect(stub).to have_been_requested.once
    expect(notifications.sole.payload).to include(mode: "backend_batch", provider: "whisper_stt")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "maps daemon failures to TranscriptionError using the daemon response body" do
    stub_request(:post, "#{endpoint}/inference")
      .to_return(status: 503, body: "model unavailable")

    expect {
      described_class.new.transcribe_batch(request)
    }.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "model unavailable")
  end

  it "maps daemon timeouts to the existing backend timeout message" do
    stub_request(:post, "#{endpoint}/inference").to_timeout

    expect {
      described_class.new.transcribe_batch(request)
    }.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "Backend transcription timed out.")
  end

  it "keeps the existing empty transcript error message" do
    stub_request(:post, "#{endpoint}/inference")
      .to_return(status: 200, body: { text: "  \n" }.to_json, headers: { "Content-Type" => "application/json" })

    expect {
      described_class.new.transcribe_batch(request)
    }.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "whisper.cpp returned an empty transcript")
  end

  describe "capability routing" do
    it "offers backend batch dictation through whisper_stt when the plugin is enabled and healthy" do
      user = Factories.user
      enable_speech_to_text!
      set_whisper_plugin_enabled!(true)

      capability = ChatSpeechToText::Capability.for(user: user)

      expect(capability.backend_batch_available?).to be(true)
      expect(capability.backend_streaming_available?).to be(false)
      expect(capability.browser_fallback_available?).to be(true)
      expect(capability.backend_provider).to be_a(described_class)
      expect(capability.as_json.dig(:modes, :backend_batch, :available)).to be(true)
    end

    it "falls back to browser dictation when the plugin is disabled" do
      user = Factories.user
      enable_speech_to_text!
      set_whisper_plugin_enabled!(false)

      capability = ChatSpeechToText::Capability.for(user: user)

      expect(capability.backend_provider).to be_nil
      expect(capability.backend_batch_available?).to be(false)
      expect(capability.browser_fallback_available?).to be(true)
      expect(capability.as_json.dig(:modes, :backend_batch, :unavailable_reason)).to eq("provider_unset")
    end

    it "falls back to browser dictation when the daemon endpoint is absent" do
      user = Factories.user
      enable_speech_to_text!
      set_whisper_plugin_enabled!(true)
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("whisper-stt").and_return(nil)

      capability = ChatSpeechToText::Capability.for(user: user)

      expect(capability.backend_provider).to be_nil
      expect(capability.backend_batch_available?).to be(false)
      expect(capability.browser_fallback_available?).to be(true)
      expect(capability.as_json.dig(:modes, :browser, :available)).to be(true)
    end
  end
end
