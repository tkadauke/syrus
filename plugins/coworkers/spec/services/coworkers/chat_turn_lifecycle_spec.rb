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
    selection = Coworkers::TurnEnvironmentSelection::Selection.new(
      kind: "standard", feature_gate_enabled: false, activation_id: nil, revision_id: nil,
      base_release_id: 1, runtime_image_id: 31, image_digest: "sha256:#{'1' * 64}",
      base_digest: "sha256:#{'1' * 64}", runtime_abi: 1, revocation_state: "available",
      runtime_image: instance_double(RuntimeImage)
    )
    @environment_resolver = instance_double(Coworkers::TurnEnvironmentSelection, resolve: selection, persist!: nil)
    allow(Coworkers::TurnEnvironmentSelection).to receive(:new).and_return(@environment_resolver)
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
    first_image = instance_double(RuntimeImage, id: 31, digest: "sha256:#{'1' * 64}")
    first = Coworkers::TurnEnvironmentSelection::Selection.new(
      kind: "custom", feature_gate_enabled: true, activation_id: 11, revision_id: 21,
      base_release_id: 1, runtime_image_id: 31, image_digest: first_image.digest,
      base_digest: "sha256:#{'3' * 64}", runtime_abi: 3, revocation_state: "available",
      runtime_image: first_image
    )
    resolver = instance_double(Coworkers::TurnEnvironmentSelection, resolve: first, persist!: nil)
    allow(Coworkers::TurnEnvironmentSelection).to receive(:new).and_return(resolver)
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    lifecycle = described_class.new(chat_session: chat, user_message: message)

    lifecycle.admission
    policy = lifecycle.execution_workload_policy(nil)

    expect(policy.runtime_image).to eq(first_image)
    expect(policy.runtime_image_digest).to eq(first.image_digest)
    expect(policy).to be_fail_closed
    expect(resolver).to have_received(:resolve).once
  end

  it "records the resolved environment after the turn is claimed" do
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    lifecycle = described_class.new(chat_session: chat, user_message: message)

    lifecycle.admission
    lifecycle.turn_started!

    expect(@environment_resolver).to have_received(:persist!).with(chat_session: chat)
  end

  it "counts only failures that occur before the agent process starts" do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    selection = Coworkers::TurnEnvironmentSelection::Selection.new(
      kind: "custom", feature_gate_enabled: true, activation_id: 11, revision_id: 21,
      base_release_id: 1, runtime_image_id: 31, image_digest: "sha256:#{'1' * 64}",
      base_digest: "sha256:#{'2' * 64}", runtime_abi: 3, revocation_state: "available",
      runtime_image: instance_double(RuntimeImage)
    )
    recovery = instance_double(Coworkers::EnvironmentRecovery, record_launch_failure!: nil)
    resolver = instance_double(Coworkers::TurnEnvironmentSelection, resolve: selection, persist!: nil)
    allow(Coworkers::TurnEnvironmentSelection).to receive(:new).and_return(resolver)
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    allow(Coworkers::EnvironmentRecovery).to receive(:new).with(environment).and_return(recovery)
    lifecycle = described_class.new(chat_session: chat, user_message: message)
    lifecycle.admission

    lifecycle.after_execution(result: instance_double(AgentInvocation::Result, success?: false,
      spawned_process_id: nil))
    lifecycle.after_execution(result: instance_double(AgentInvocation::Result, success?: false,
      spawned_process_id: 99))
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    selection = Coworkers::TurnEnvironmentSelection::Selection.new(
      kind: "custom", feature_gate_enabled: true, activation_id: 11, revision_id: 21,
      base_release_id: 1, runtime_image_id: 31, image_digest: "sha256:#{'1' * 64}",
      base_digest: "sha256:#{'2' * 64}", runtime_abi: 3, revocation_state: "available",
      runtime_image: instance_double(RuntimeImage)
    )
    recovery = instance_double(Coworkers::EnvironmentRecovery, record_launch_failure!: nil)
    resolver = instance_double(Coworkers::TurnEnvironmentSelection, resolve: selection, persist!: nil)
    allow(Coworkers::TurnEnvironmentSelection).to receive(:new).and_return(resolver)
    allow(Coworkers::PrivilegedGrantGate).to receive(:turn_admission).and_return({})
    allow(Coworkers::EnvironmentRecovery).to receive(:new).with(environment).and_return(recovery)
    lifecycle = described_class.new(chat_session: chat, user_message: message)
    lifecycle.admission
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
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
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
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
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
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
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
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
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
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
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
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
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
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
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
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
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
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
    lifecycle.after_execution(exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).to have_received(:record_launch_failure!).once
      .with(11, reason: "agent_process_not_started")
  end

  it "does not count a late exception after an agent process started" do
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
    result = instance_double(AgentInvocation::Result, success?: false, spawned_process_id: 99)

    lifecycle.after_execution(result: result)
    lifecycle.after_execution(result: result, exception: ActiveRecord::Deadlocked.new("late persistence failure"))

    expect(recovery).not_to have_received(:record_launch_failure!)
  end
end
