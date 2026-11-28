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

  it "pins one immutable activation at admission even when publication advances concurrently" do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    first_image = instance_double(RuntimeImage, id: 31, digest: "sha256:#{'1' * 64}")
    replacement_image = instance_double(RuntimeImage, id: 32, digest: "sha256:#{'2' * 64}")
    first = Coworkers::EnvironmentActiveSelection::Selection.new(
      activation_id: 11, revision_id: 21, runtime_image_id: 31,
      image_digest: first_image.digest, runtime_image: first_image
    )
    replacement = Coworkers::EnvironmentActiveSelection::Selection.new(
      activation_id: 12, revision_id: 22, runtime_image_id: 32,
      image_digest: replacement_image.digest, runtime_image: replacement_image
    )
    allow(Coworkers::EnvironmentActiveSelection).to receive(:resolve).with(environment).and_return(first, replacement)
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    lifecycle = described_class.new(chat_session: chat, user_message: message)

    lifecycle.admission
    policy = lifecycle.execution_workload_policy(nil)

    expect(policy.runtime_image).to eq(first_image)
    expect(policy.runtime_image_digest).to eq(first.image_digest)
    expect(policy).to be_fail_closed
    expect(Coworkers::EnvironmentActiveSelection).to have_received(:resolve).once
  end

  it "counts only failures that occur before the agent process starts" do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    selection = Coworkers::EnvironmentActiveSelection::Selection.new(
      activation_id: 11, revision_id: 21, runtime_image_id: 31,
      image_digest: "sha256:#{'1' * 64}", runtime_image: instance_double(RuntimeImage)
    )
    recovery = instance_double(Coworkers::EnvironmentRecovery, record_launch_failure!: nil)
    allow(Coworkers::EnvironmentActiveSelection).to receive(:resolve).with(environment).and_return(selection)
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    allow(Coworkers::EnvironmentRecovery).to receive(:new).with(environment).and_return(recovery)
    lifecycle = described_class.new(chat_session: chat, user_message: message)
    lifecycle.admission

    lifecycle.after_execution(result: instance_double(AgentInvocation::Result, success?: false,
      spawned_process_id: nil))
    lifecycle.after_execution(result: instance_double(AgentInvocation::Result, success?: false,
      spawned_process_id: 99))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end
end
