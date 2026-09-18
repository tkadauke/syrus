require "rails_helper"

RSpec.describe ChatScopedEventEvaluatorJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, chat_provider: "claude") }
  let(:event) do
    ChatScopedEvent.create!(
      chat_session: chat_session,
      source_kind: "insight_created",
      payload: { "summary" => "New insight" }
    )
  end

  it "evaluates the scoped event for the target chat" do
    evaluator = instance_double(ChatEventEvaluator, call: { "decision" => "no_op" })
    allow(ChatEventEvaluator).to receive(:new)
      .with(event: event, chat_session: chat_session)
      .and_return(evaluator)

    described_class.perform_now(event.id, chat_session.id)

    expect(evaluator).to have_received(:call)
  end

  it "records no-op decisions without creating a visible wakeup turn" do
    event.update!(
      source_kind: "pull_request_merged",
      payload: { "kind" => "pull_request_merged", "severity" => "info", "summary" => "PR merged cleanly" }
    )
    evaluator = instance_double(ChatEventEvaluator, call: { "decision" => "no_op", "reason" => "harmless merge event" })
    allow(ChatEventEvaluator).to receive(:new).and_return(evaluator)

    expect {
      described_class.perform_now(event.id, chat_session.id)
    }.not_to change(ChatMessage, :count)

    expect(chat_session.wakeups).to be_empty
    expect(event.reload).to be_pending
  end

  it "creates a structured wakeup for actionable evaluator decisions" do
    result = {
      "decision" => "act",
      "reason" => "critical failure needs inspection",
      "urgency" => 1.0,
      "confidence" => 0.9,
      "handoff_prompt" => "Inspect the failed workflow and propose the next action."
    }
    evaluator = instance_double(ChatEventEvaluator, call: result)
    allow(ChatEventEvaluator).to receive(:new).and_return(evaluator)

    described_class.perform_now(event.id, chat_session.id)

    wakeup = chat_session.wakeups.last
    expect(wakeup.prompt).to include("Before acting, read current Syrus state")
    expect(wakeup.prompt).to include("Inspect the failed workflow")
    expect(wakeup.metadata).to include(
      "source" => "scoped_event_wakeup",
      "kind" => "scoped_event_evaluator_handoff",
      "scoped_event_wakeup" => true,
      "scoped_event_id" => event.id,
      "evaluator_decision" => result
    )
    expect(wakeup.metadata).not_to have_key("supervisor_event")
    expect(wakeup.metadata["scoped_event"]).to include("summary" => "New insight", "scoped_event_id" => event.id)
    expect(event.reload).to be_delivered
  end

  describe "judgment on widened success-kind events" do
    around do |example|
      original_runner = ChatEventEvaluator.runner
      example.run
    ensure
      ChatEventEvaluator.runner = original_runner
    end

    def stub_provider_watching_for(cue)
      ChatEventEvaluator.runner = lambda do |**kwargs|
        watched = kwargs.fetch(:transcript_jsonl).to_s.include?(cue)
        decision = watched ? "respond" : "no_op"
        reason = watched ? "operator explicitly asked to be told" : "nothing in transcript suggests interest"
        Struct.new(:final_text).new(JSON.generate(decision: decision, reason: reason, urgency: watched ? 0.6 : 0.1, confidence: 0.8))
      end
    end

    it "creates a real wakeup for a success event the operator explicitly asked to hear about" do
      chat_session.messages.create!(role: "user", content: { "text" => "Sounds good — let me know when this lands." })
      event.update!(
        source_kind: "job_implemented",
        payload: { "kind" => "job_implemented", "severity" => "info", "summary" => "Opened the PR" }
      )
      stub_provider_watching_for("let me know when this lands")

      described_class.perform_now(event.id, chat_session.id)

      expect(event.reload).to be_delivered
      expect(event.evaluator_result["decision"]).to eq("respond")
      wakeup = chat_session.wakeups.last
      expect(wakeup).to be_present
      expect(wakeup.metadata["evaluator_decision"]["reason"]).to eq("operator explicitly asked to be told")
    end

    it "stays no_op for the same success-event kind when nothing in the chat shows the operator is watching" do
      chat_session.messages.create!(role: "user", content: { "text" => "Thanks, let's move on to the login page redesign next." })
      event.update!(
        source_kind: "job_implemented",
        payload: { "kind" => "job_implemented", "severity" => "info", "summary" => "Opened the PR" }
      )
      stub_provider_watching_for("let me know when this lands")

      expect {
        described_class.perform_now(event.id, chat_session.id)
      }.not_to change(ChatWakeup, :count)

      expect(event.reload).to be_pending
      expect(event.evaluator_result["decision"]).to eq("no_op")
    end
  end

  it "ignores a mismatched target chat" do
    other_chat = ChatSession.create!(user: user, chat_provider: "claude")
    allow(ChatEventEvaluator).to receive(:new)

    described_class.perform_now(event.id, other_chat.id)

    expect(ChatEventEvaluator).not_to have_received(:new)
  end

  it "retries failed evaluator events" do
    event.record_evaluator_failure!("JSON::ParserError: evaluator did not return JSON")
    evaluator = instance_double(ChatEventEvaluator, call: { "decision" => "no_op", "reason" => "handled on retry" })
    allow(ChatEventEvaluator).to receive(:new)
      .with(event: event, chat_session: chat_session)
      .and_return(evaluator)

    described_class.perform_now(event.id, chat_session.id)

    expect(evaluator).to have_received(:call)
  end

  it "does not duplicate visible wakeups when an actionable completed event is retried" do
    event.record_evaluator_result!(
      "decision" => "respond",
      "reason" => "operator should know",
      "handoff_prompt" => "Report the event."
    )

    expect {
      described_class.perform_now(event.id, chat_session.id)
      described_class.perform_now(event.id, chat_session.id)
    }.to change(ChatWakeup, :count).by(1)

    expect(event.reload).to be_delivered
  end

  it "skips already delivered scoped events" do
    event.update!(
      delivery_state: "delivered",
      delivered_at: Time.current,
      evaluator_state: "completed",
      evaluator_result: { "decision" => "act" }
    )
    allow(ChatEventEvaluator).to receive(:new)

    described_class.perform_now(event.id, chat_session.id)

    expect(ChatEventEvaluator).not_to have_received(:new)
  end
end
