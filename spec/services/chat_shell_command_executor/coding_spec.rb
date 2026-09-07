require "rails_helper"

RSpec.describe ChatShellCommandExecutor::Coding do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding", coding_checkout_branch: "syrus-chat-1") }
  let(:executor) { described_class.new }

  def command_record(**attrs)
    chat_session.chat_shell_commands.create!(
      { user: user, command: "echo hi", started_at: Time.current }.merge(attrs)
    )
  end

  # #run! is exercised end-to-end (ProcessRunner stubbing, output capture,
  # outcome mapping) via spec/jobs/chat_shell_command_job_spec.rb, which
  # invokes this class through ChatShellCommandJob#run_command!.

  it "is resolved by ChatShellCommandExecutor::Base.for(\"coding\")" do
    expect(ChatShellCommandExecutor::Base.for("coding")).to be_a(described_class)
  end

  describe "#feature_enabled?" do
    it "delegates to Feature.coding_mode_enabled?" do
      allow(Feature).to receive(:coding_mode_enabled?).and_return(true)
      expect(executor.feature_enabled?).to eq(true)
    end
  end

  describe "#precondition_error" do
    it "requires a repository" do
      chat = ChatSession.create!(user: user, mode: "coding", coding_checkout_branch: "syrus-chat-1")
      expect(executor.precondition_error(chat)).to eq("No repository attached to this chat.")
    end

    it "requires an active coding checkout" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
      expect(executor.precondition_error(chat)).to eq("No active coding checkout for this chat.")
    end

    it "returns nil once a repository and checkout are present" do
      expect(executor.precondition_error(chat_session)).to be_nil
    end
  end

  describe "#cancellable?" do
    it "is false while no spawned_process has been registered yet" do
      expect(executor.cancellable?(command_record)).to eq(false)
    end

    it "is true once a live spawned_process is attached" do
      spawned_process = SpawnedProcess.create!(kind: "chat_shell_command", command: "echo hi", hostname: "worker-1", started_at: Time.current)
      expect(executor.cancellable?(command_record(spawned_process: spawned_process))).to eq(true)
    end

    it "is false once the spawned_process has finished" do
      spawned_process = SpawnedProcess.create!(
        kind: "chat_shell_command", command: "echo hi", hostname: "worker-1",
        started_at: Time.current, finished_at: Time.current, outcome: "succeeded"
      )
      expect(executor.cancellable?(command_record(spawned_process: spawned_process))).to eq(false)
    end
  end

  describe "#request_cancel!" do
    it "requests a kill on the attached spawned_process" do
      spawned_process = SpawnedProcess.create!(kind: "chat_shell_command", command: "echo hi", hostname: "worker-1", started_at: Time.current)
      command = command_record(spawned_process: spawned_process)

      executor.request_cancel!(command, user: user)

      expect(spawned_process.reload.kill_requested_at).to be_present
      expect(spawned_process.kill_requested_by_user_id).to eq(user.id)
    end
  end
end
