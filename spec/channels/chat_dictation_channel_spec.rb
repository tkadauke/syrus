require "rails_helper"

RSpec.describe ChatDictationChannel, type: :channel do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:provider_stream) { FakeStreamingProviderStream.new }
  let(:provider) { FakeStreamingProvider.new(provider_stream) }

  before do
    stub_connection current_user: user
    allow_any_instance_of(described_class).to receive(:start_timeout_thread)
  end

  def enable_speech_to_text!
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
  end

  def stub_streaming_provider!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
  end

  it "rejects subscriptions when the feature is disabled" do
    stub_streaming_provider!

    subscribe(chat_session_id: chat.id)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions when backend streaming is unavailable" do
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(instance_double(ChatSpeechToText::Providers::Base, streaming?: false))

    subscribe(chat_session_id: chat.id)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions to another user's chat" do
    enable_speech_to_text!
    stub_streaming_provider!
    other_chat = ChatSession.create!(user: Factories.user)

    subscribe(chat_session_id: other_chat.id)

    expect(subscription).to be_rejected
  end

  it "starts an ephemeral dictation session and transmits stable session metadata" do
    enable_speech_to_text!
    stub_streaming_provider!
    subscribe(chat_session_id: chat.id)

    perform :receive, { "type" => "start", "content_type" => "audio/webm;codecs=opus", "language" => "en" }

    expect(subscription).to be_confirmed
    expect(provider.requests.first).to have_attributes(content_type: "audio/webm", language: "en")
    expect(transmissions.last).to include(
      "type" => "started",
      "sequence" => 1,
      "transport" => "action_cable",
      "fallback" => {
        "mode" => "backend_batch",
        "buffered_audio_required" => true,
        "endpoint" => "/api/v1/app/chats/#{chat.id}/speech_to_text"
      }
    )
    expect(transmissions.last["session_id"]).to be_present
    expect(ChatMessage.count).to eq(0)
  end

  it "passes ordered audio chunks to the provider and emits ack frames" do
    enable_speech_to_text!
    stub_streaming_provider!
    subscribe(chat_session_id: chat.id)
    perform :receive, { "type" => "start", "content_type" => "audio/webm" }

    perform :receive, { "type" => "audio_chunk", "sequence" => 1, "audio" => Base64.strict_encode64("audio") }

    expect(provider_stream.audio).to eq([ "audio" ])
    expect(transmissions.last).to include("type" => "ack", "sequence" => 2, "chunk_sequence" => 1)
  end

  it "emits provider transcript deltas with monotonically increasing sequence numbers" do
    enable_speech_to_text!
    stub_streaming_provider!
    subscribe(chat_session_id: chat.id)
    perform :receive, { "type" => "start", "content_type" => "audio/webm" }
    session_id = transmissions.last["session_id"]

    provider_stream.emit_delta("ship", final: false)
    provider_stream.emit_delta("ship it", final: true)

    deltas = transmissions.last(2)
    expect(deltas.first).to include("type" => "transcript_delta", "session_id" => session_id, "sequence" => 2, "text" => "ship", "final" => false, "confidence" => nil)
    expect(deltas.second).to include("type" => "transcript_delta", "session_id" => session_id, "sequence" => 3, "text" => "ship it", "final" => true, "confidence" => nil)
  end

  it "fails out-of-order chunks with fallback state and does not send them to the provider" do
    enable_speech_to_text!
    stub_streaming_provider!
    subscribe(chat_session_id: chat.id)
    perform :receive, { "type" => "start", "content_type" => "audio/webm" }

    perform :receive, { "type" => "audio_chunk", "sequence" => 2, "audio" => Base64.strict_encode64("late") }

    expect(provider_stream.audio).to eq([])
    expect(transmissions.last).to include(
      "type" => "error",
      "code" => "speech_to_text_stream_failed",
      "fallback" => include("mode" => "backend_batch", "buffered_audio_required" => true)
    )
  end

  it "finalizes and cancels lifecycle messages" do
    enable_speech_to_text!
    stub_streaming_provider!
    subscribe(chat_session_id: chat.id)
    perform :receive, { "type" => "start", "content_type" => "audio/webm" }

    perform :receive, { "type" => "stop" }
    expect(provider_stream.finished).to eq(true)

    perform :receive, { "type" => "cancel" }
    expect(transmissions.last).to include("type" => "cancelled")
  end

  class FakeStreamingProvider
    attr_reader :requests

    def initialize(stream)
      @stream = stream
      @requests = []
    end

    def streaming?
      true
    end

    def stream_transcription(request)
      @requests << request
      @stream.request = request
      @stream
    end
  end

  class FakeStreamingProviderStream
    attr_accessor :request
    attr_reader :audio, :finished

    def initialize
      @audio = []
      @finished = false
    end

    def accept_audio(bytes)
      @audio << bytes
    end

    def finish
      @finished = true
      request.on_complete.call(reason: "finalized")
    end

    def cancel; end

    def emit_delta(text, final:)
      request.on_delta.call(ChatSpeechToText::Providers::StreamingDelta.new(text: text, final: final, confidence: nil))
    end
  end
end
