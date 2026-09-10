require "rails_helper"

RSpec.describe ChatShellCommandExecutor::Local do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "local") }
  let(:executor) { described_class.new }

  def command_record(**attrs)
    chat_session.chat_shell_commands.create!(
      { user: user, command: "echo hi", started_at: Time.current }.merge(attrs)
    )
  end

  def connected_daemon_session
    session = LocalDaemonSession.create!(chat_session: chat_session, user: user)
    session.mark_connected!(repo: "acme/widgets", branch: "main")
    session
  end

  it "is resolved by ChatShellCommandExecutor::Base.for(\"local\")" do
    expect(ChatShellCommandExecutor::Base.for("local")).to be_a(described_class)
  end

  describe "#feature_enabled?" do
    it "delegates to Feature.local_mode_enabled?" do
      allow(Feature).to receive(:local_mode_enabled?).and_return(true)
      expect(executor.feature_enabled?).to eq(true)
    end
  end

  describe "#precondition_error" do
    it "returns the disconnected error when no daemon session exists" do
      expect(executor.precondition_error(chat_session)).to eq(described_class::DISCONNECTED_ERROR)
    end

    it "returns the disconnected error when the daemon session isn't connected" do
      LocalDaemonSession.create!(chat_session: chat_session, user: user, disconnected_at: Time.current)
      expect(executor.precondition_error(chat_session)).to eq(described_class::DISCONNECTED_ERROR)
    end

    it "returns the disconnected error when the session row exists but the daemon has never actually handshaken (JOB-609 visual review)" do
      LocalDaemonSession.create!(chat_session: chat_session, user: user)
      expect(chat_session.reload.daemon_connected?).to eq(false)

      expect(executor.precondition_error(chat_session)).to eq(described_class::DISCONNECTED_ERROR)
    end

    it "returns nil once a daemon session is connected" do
      connected_daemon_session
      expect(executor.precondition_error(chat_session)).to be_nil
    end
  end

  describe "#run!" do
    it "returns an error result when no daemon is connected" do
      command = command_record
      result = executor.run!(command)

      expect(result.outcome).to eq("error")
      expect(result.output).to eq(described_class::DISCONNECTED_ERROR)
    end

    it "returns an error result, and never dispatches a tool call, when the session row exists but the daemon hasn't handshaken yet (JOB-609 visual review)" do
      LocalDaemonSession.create!(chat_session: chat_session, user: user)
      command = command_record

      result = executor.run!(command)

      expect(result.outcome).to eq("error")
      expect(result.output).to eq(described_class::DISCONNECTED_ERROR)
      expect(command.reload.local_tool_call).to be_nil
      expect(LocalToolCall.where(chat_session: chat_session)).to be_empty
    end

    it "dispatches a run_command tool call, stores it on the record, and reports success" do
      connected_daemon_session
      command = command_record(command: "echo hi")

      Thread.new do
        sleep 0.05
        call = LocalToolCall.find_by(chat_session: chat_session, tool_name: "run_command")
        call.complete!(result: { "stdout" => "hi\n", "stderr" => "", "exit_code" => 0 })
      end

      result = executor.run!(command)

      expect(command.reload.local_tool_call).to be_present
      expect(command.local_tool_call.tool_input).to eq("command" => "echo hi")
      expect(result.outcome).to eq("succeeded")
      expect(result.output).to eq("hi\n")
      expect(result.exit_status).to eq(0)
    end

    it "reports a failed outcome for a non-zero exit code" do
      connected_daemon_session
      command = command_record

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).complete!(result: { "stdout" => "", "stderr" => "boom", "exit_code" => 1 })
      end

      result = executor.run!(command)

      expect(result.outcome).to eq("failed")
      expect(result.exit_status).to eq(1)
      expect(result.output).to eq("boom")
    end

    it "reports a killed outcome when the daemon reports the command was cancelled" do
      connected_daemon_session
      command = command_record

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).complete!(result: { "stdout" => "partial", "stderr" => "", "exit_code" => -1, "killed" => true })
      end

      result = executor.run!(command)

      expect(result.outcome).to eq("killed")
      expect(result.output).to eq("partial")
    end

    it "reports an error outcome when the daemon call itself fails" do
      connected_daemon_session
      command = command_record

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).fail!(error: "daemon exploded")
      end

      result = executor.run!(command)

      expect(result.outcome).to eq("error")
      expect(result.output).to eq("daemon exploded")
    end

    it "caps oversized combined stdout+stderr the same way Coding's streamed output is capped" do
      connected_daemon_session
      command = command_record
      huge_stdout = "a" * (ChatShellCommand::MAX_OUTPUT_BYTES + 10)

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).complete!(result: { "stdout" => huge_stdout, "stderr" => "", "exit_code" => 0 })
      end

      result = executor.run!(command)

      expect(result.outcome).to eq("succeeded")
      expect(result.output.bytesize).to be <= ChatShellCommand::MAX_OUTPUT_BYTES + ChatShellCommand::TRUNCATION_NOTICE.bytesize
      expect(result.output).to end_with(ChatShellCommand::TRUNCATION_NOTICE)
    end
  end

  describe "#cancellable?" do
    it "is false when no local_tool_call is attached" do
      command = command_record
      expect(executor.cancellable?(command)).to eq(false)
    end

    it "is true once the local_tool_call is dispatched" do
      session = connected_daemon_session
      call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat_session, tool_use_id: "x", tool_name: "run_command", state: "dispatched")
      command = command_record(local_tool_call: call)

      expect(executor.cancellable?(command)).to eq(true)
    end

    it "is false once the local_tool_call has completed" do
      session = connected_daemon_session
      call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat_session, tool_use_id: "x", tool_name: "run_command", state: "completed")
      command = command_record(local_tool_call: call)

      expect(executor.cancellable?(command)).to eq(false)
    end
  end

  describe "#request_cancel!" do
    it "broadcasts a cancel message for the attached local_tool_call" do
      session = connected_daemon_session
      call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat_session, tool_use_id: "x", tool_name: "run_command", state: "dispatched")
      command = command_record(local_tool_call: call)

      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |stream, msg| broadcasts << [ stream, msg ] }

      executor.request_cancel!(command, user: user)

      expect(broadcasts).to include([ "local_daemon_session_#{session.id}_tool_calls", { type: "cancel", tool_call_id: call.id } ])
    end

    it "is a no-op when no local_tool_call is attached" do
      command = command_record
      expect { executor.request_cancel!(command, user: user) }.not_to raise_error
    end
  end
end
