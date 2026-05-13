require "rails_helper"

RSpec.describe OperatorChat do
  let(:repository) { Factories.repository(allow_operator_chat: "in_syrus") }
  let(:run) { Factories.job(repository: repository).initial_run }

  it "delivers in-Syrus questions as chat messages" do
    expect {
      described_class.dispatch!(run: run, question: "Which API?", context: "Two APIs are plausible.")
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)

    message = ChatMessage.last
    expect(message.role).to eq("system")
    expect(message.content).to include(
      "kind" => "operator_question",
      "question" => "Which API?",
      "context" => "Two APIs are plausible."
    )
  end

  it "routes Telegram questions through the Telegram channel" do
    repository.update!(allow_operator_chat: "telegram")
    expect(OperatorChat::Channels::Telegram).to receive(:deliver!)

    record = described_class.dispatch!(run: run, question: "Which API?", context: "Two APIs are plausible.")

    expect(record.channel).to eq("telegram")
  end

  it "raises a disabled error before persisting when disabled" do
    repository.update!(allow_operator_chat: "disabled")

    expect {
      described_class.dispatch!(run: run, question: "Which API?", context: "Two APIs are plausible.")
    }.to raise_error(OperatorChat::Disabled)
    expect(OperatorQuestion.count).to eq(0)
  end
end
