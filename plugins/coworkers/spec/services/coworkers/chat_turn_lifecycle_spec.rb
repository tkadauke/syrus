require "rails_helper"

RSpec.describe Coworkers::ChatTurnLifecycle do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat) { ChatSession.create!(user:, repository:) }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "hello" }) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:scope) { Syrus::EffectScope.new(label: "coworker chat turn lifecycle spec") }

  before do
    Coworkers::ChatExtension.install_into(scope)
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
  end

  after { scope.dispose }

  it "owns the coworker turn context, admission, workspace isolation, and lock" do
    admission = { queue: :chat }
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).with(coworker).and_return(admission)
    expect(Coworkers::OperationLock).to receive(:with).with(coworker, wait: 30.minutes.to_i).and_yield

    lifecycle = described_class.new(chat_session: chat, user_message: message)

    expect(described_class).to be_applies_to(chat_session: chat, user_message: message)
    expect(lifecycle.admission).to eq(admission)
    expect(lifecycle.context).to eq(chat)
    expect(lifecycle).to be_isolated_workspace
    expect(lifecycle.synchronize { :ran }).to eq(:ran)
  end

  it "supplies plugin-owned copy for rejected admission" do
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission)
      .and_return(outcome: "blocked")

    expect(described_class.new(chat_session: chat, user_message: message).admission)
      .to include(outcome: "blocked", message: I18n.t("coworkers.confinement_unavailable", locale: user.locale))
  end

  it "does not own an ordinary chat merely because a coworker is rostered" do
    ordinary = ChatSession.create!(user:, repository: nil)
    Coworkers::ChatAgent.create!(chat_session: ordinary, coworker:, added_by_user: user)

    expect(described_class).not_to be_applies_to(chat_session: ordinary, user_message: nil)
    expect(ordinary.reload.repository).to be_nil
  end
end
