require "rails_helper"

RSpec.describe ChatSpeechToText::StreamingSession do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:provider_stream) { FakeProviderStream.new }
  let(:provider) { FakeStreamingProvider.new(provider_stream) }
  let(:clock_time) { Time.current }
  let(:clock) { -> { clock_time } }

  def session
    described_class.new(
      chat_session: chat,
      provider: provider,
      content_type: "audio/webm",
      id: "dictation-session",
      clock: clock
    )
  end

  it "starts a provider stream with callback hooks and metadata" do
    deltas = []
    started = session

    started.start(
      on_delta: ->(delta) { deltas << delta.text },
      on_error: ->(_) {},
      on_complete: ->(*) {}
    )
    provider_stream.emit_delta("hello")

    expect(provider.requests.first).to have_attributes(content_type: "audio/webm", language: nil, prompt: nil)
    expect(deltas).to eq([ "hello" ])
  end

  it "accepts monotonically ordered base64 audio chunks" do
    started = session
    started.start(on_delta: ->(_) {}, on_error: ->(_) {}, on_complete: ->(*) {})

    started.accept_chunk(sequence: 1, audio_base64: Base64.strict_encode64("one"))
    started.accept_chunk(sequence: 2, audio_base64: Base64.strict_encode64("two"))

    expect(provider_stream.audio).to eq([ "one", "two" ])
  end

  it "rejects out-of-order chunks before they reach the provider" do
    started = session
    started.start(on_delta: ->(_) {}, on_error: ->(_) {}, on_complete: ->(*) {})

    expect {
      started.accept_chunk(sequence: 2, audio_base64: Base64.strict_encode64("late"))
    }.to raise_error(ChatSpeechToText::Providers::TranscriptionError, /Expected 1, got 2/)
    expect(provider_stream.audio).to eq([])
  end

  it "marks idle sessions as timed out" do
    now = Time.current
    mutable_now = now
    idle_session = described_class.new(
      chat_session: chat,
      provider: provider,
      content_type: "audio/webm",
      clock: -> { mutable_now }
    )
    idle_session.start(on_delta: ->(_) {}, on_error: ->(_) {}, on_complete: ->(*) {})

    mutable_now = now + described_class::IDLE_TIMEOUT + 1.second

    expect(idle_session).to be_timed_out
  end

  class FakeProviderStream
    attr_reader :audio

    def initialize
      @audio = []
    end

    def accept_audio(bytes)
      @audio << bytes
    end

    def finish; end

    def cancel; end

    def emit_delta(text)
      @request.on_delta.call(ChatSpeechToText::Providers::StreamingDelta.new(text: text, final: false, confidence: nil))
    end

    def request=(request)
      @request = request
    end
  end

  class FakeStreamingProvider
    attr_reader :requests

    def initialize(stream)
      @stream = stream
      @requests = []
    end

    def stream_transcription(request)
      @requests << request
      @stream.request = request
      @stream
    end
  end
end
