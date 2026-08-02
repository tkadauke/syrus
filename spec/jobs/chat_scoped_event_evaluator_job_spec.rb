require "rails_helper"

RSpec.describe ChatScopedEventEvaluatorJob do
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

  it "ignores a mismatched target chat" do
    other_chat = ChatSession.create!(user: user, chat_provider: "claude")
    allow(ChatEventEvaluator).to receive(:new)

    described_class.perform_now(event.id, other_chat.id)

    expect(ChatEventEvaluator).not_to have_received(:new)
  end
end
