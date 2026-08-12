require "rails_helper"

RSpec.describe ChatSpeechToText::Telemetry do
  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Current.reset
  end

  after do
    Current.reset
  end

  it "indexes mode_selected events as info with chat_speech_to_text source and context" do
    expect {
      described_class.log("mode_selected", chat_id: 42, mode: "backend_batch", provider: "openai")
    }.to change(OperationalLogEvent, :count).by(1)

    event = OperationalLogEvent.last
    expect(event.level).to eq("info")
    expect(event.source).to eq("chat_speech_to_text")
    expect(event.message).to eq("chat_speech_to_text.mode_selected")
    expect(event.context).to include("chat_id" => "42", "mode" => "backend_batch", "provider" => "openai")
  end

  it "indexes transcribed events as info" do
    described_class.log("transcribed", chat_id: 42, mode: "backend_batch", provider: "openai", duration_ms: 12.3)

    event = OperationalLogEvent.last
    expect(event.level).to eq("info")
    expect(event.context).to include("chat_id" => "42", "duration_ms" => "12.3")
  end

  it "indexes fallback events as warn" do
    described_class.log("fallback", chat_id: 42, requested_mode: "backend_streaming", fallback_mode: "backend_batch", reason: "unavailable")

    event = OperationalLogEvent.last
    expect(event.level).to eq("warn")
    expect(event.context).to include("requested_mode" => "backend_streaming", "fallback_mode" => "backend_batch")
  end

  it "indexes error events as error" do
    described_class.log("error", chat_id: 42, mode: "backend_batch", error_class: "Boom")

    event = OperationalLogEvent.last
    expect(event.level).to eq("error")
    expect(event.context).to include("error_class" => "Boom")
  end

  it "still instruments and logs even when indexing is disabled" do
    Feature.find_by!(slug: "operational_log_indexing").update!(enabled: false)
    Current.reset

    events = []
    subscription = ActiveSupport::Notifications.subscribe("chat_speech_to_text.mode_selected") { |*args| events << ActiveSupport::Notifications::Event.new(*args) }

    expect {
      described_class.log("mode_selected", chat_id: 42, mode: "backend_batch")
    }.not_to change(OperationalLogEvent, :count)

    expect(events.size).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "does not raise when OperationalLogging.ingest errors" do
    allow(OperationalLogging).to receive(:ingest).and_raise("boom")

    expect { described_class.log("mode_selected", chat_id: 42) }.not_to raise_error
  end
end
