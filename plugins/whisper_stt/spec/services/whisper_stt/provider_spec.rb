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

  it "advertises streaming only when the gateway reports that capability" do
    stub_request(:get, "#{endpoint}/health")
      .to_return(status: 200, body: { capabilities: { streaming: true } }.to_json)
    expect(described_class.new.streaming?).to be(true)

    stub_request(:get, "#{endpoint}/health")
      .to_return(status: 200, body: { capabilities: { streaming: false } }.to_json)
    expect(described_class.new.streaming?).to be(false)
  end

  it "emits revised interim hypotheses and one final hypothesis" do
    stub_request(:post, "#{endpoint}/stream/sessions").to_return(status: 201, body: { id: "stream-1" }.to_json)
    stub_request(:put, "#{endpoint}/stream/sessions/stream-1/chunks/1").with(body: "first").to_return(status: 200, body: { text: "ship" }.to_json)
    stub_request(:put, "#{endpoint}/stream/sessions/stream-1/chunks/2").with(body: "second").to_return(status: 200, body: { text: "ship it" }.to_json)
    stub_request(:post, "#{endpoint}/stream/sessions/stream-1/finish").to_return(status: 200, body: { text: "ship it now" }.to_json)
    deltas = []
    completions = []
    stream = described_class.new.stream_transcription(ChatSpeechToText::Providers::StreamingRequest.new(
      content_type: "audio/webm", language: "en", prompt: nil,
      on_delta: ->(delta) { deltas << [ delta.text, delta.final ] },
      on_error: ->(error) { raise error }, on_complete: ->(payload) { completions << payload }
    ))

    stream.accept_audio("first")
    stream.accept_audio("second")
    stream.finish

    expect(deltas).to eq([ [ "ship", false ], [ "ship it", false ], [ "ship it now", true ] ])
    expect(completions).to eq([ { reason: "finalized" } ])
  end

  it "cancels the daemon session when streaming fails" do
    stub_request(:post, "#{endpoint}/stream/sessions").to_return(status: 201, body: { id: "stream-1" }.to_json)
    stub_request(:put, "#{endpoint}/stream/sessions/stream-1/chunks/1").to_return(status: 503, body: { error: "decode failed" }.to_json)
    cancellation = stub_request(:delete, "#{endpoint}/stream/sessions/stream-1").to_return(status: 200, body: { cancelled: true }.to_json)
    errors = []
    stream = described_class.new.stream_transcription(ChatSpeechToText::Providers::StreamingRequest.new(
      content_type: "audio/webm", language: nil, prompt: nil,
      on_delta: ->(_) { }, on_error: ->(error) { errors << error }, on_complete: ->(*) { }
    ))

    expect { stream.accept_audio("audio") }.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "decode failed")
    expect(errors.sole.message).to eq("decode failed")
    expect(cancellation).to have_been_requested.once
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

      stub_request(:get, "#{endpoint}/health").to_return(status: 200, body: { capabilities: { streaming: true } }.to_json)
      capability = ChatSpeechToText::Capability.for(user: user)

      expect(capability.backend_batch_available?).to be(true)
      expect(capability.backend_streaming_available?).to be(true)
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
