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
      "scoped_event_wakeup" => true,
      "scoped_event_id" => event.id,
      "evaluator_decision" => result
    )
    expect(wakeup.metadata["supervisor_event"]).to include("summary" => "New insight", "scoped_event_id" => event.id)
    expect(event.reload).to be_delivered
  end

  it "ignores a mismatched target chat" do
    other_chat = ChatSession.create!(user: user, chat_provider: "claude")
    allow(ChatEventEvaluator).to receive(:new)

    described_class.perform_now(event.id, other_chat.id)

    expect(ChatEventEvaluator).not_to have_received(:new)
  end
end
