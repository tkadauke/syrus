require "rails_helper"

RSpec.describe ChatShellCommand do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  def build_command(**attrs)
    chat_session.chat_shell_commands.create!(
      { user: user, command: "echo hi", started_at: Time.current }.merge(attrs)
    )
  end

  it "requires a command" do
    command = chat_session.chat_shell_commands.new(user: user, started_at: Time.current)

    expect(command).not_to be_valid
    expect(command.errors[:command]).to be_present
  end

  it "rejects an outcome outside the known set" do
    command = build_command
    command.outcome = "sideways"

    expect(command).not_to be_valid
    expect(command.errors[:outcome]).to be_present
  end

  it "allows a nil outcome while running" do
    command = build_command

    expect(command).to be_valid
    expect(command).to be_running
  end

  it "is no longer running once finished_at is set" do
    command = build_command(finished_at: Time.current, outcome: "succeeded")

    expect(command).to be_finished
    expect(command).not_to be_running
  end

  describe ".append_capped" do
    it "concatenates chunks under the cap" do
      result = described_class.append_capped("hello ", "world")

      expect(result).to eq("hello world")
    end

    it "truncates once the cap is exceeded and appends a notice" do
      huge_chunk = "a" * (described_class::MAX_OUTPUT_BYTES + 10)

      result = described_class.append_capped("", huge_chunk)

      expect(result.bytesize).to be > described_class::MAX_OUTPUT_BYTES
      expect(result).to end_with(described_class::TRUNCATION_NOTICE)
    end

    it "stops appending once already at the cap" do
      already_full = "a" * described_class::MAX_OUTPUT_BYTES

      result = described_class.append_capped(already_full, "more")

      expect(result).to eq(already_full)
    end
  end

  describe "#cancellable?" do
    it "is false while no spawned_process has been registered yet" do
      command = build_command

      expect(command.cancellable?).to eq(false)
    end

    it "is true once a live spawned_process is attached" do
      spawned_process = SpawnedProcess.create!(
        kind: "chat_shell_command", command: "echo hi", hostname: "worker-1", started_at: Time.current
      )
      command = build_command(spawned_process: spawned_process)

      expect(command.cancellable?).to eq(true)
    end

    it "is false once the spawned_process has finished" do
      spawned_process = SpawnedProcess.create!(
        kind: "chat_shell_command", command: "echo hi", hostname: "worker-1",
        started_at: Time.current, finished_at: Time.current, outcome: "succeeded"
      )
      command = build_command(spawned_process: spawned_process)

      expect(command.cancellable?).to eq(false)
    end

    it "is false once the command itself has finished" do
      spawned_process = SpawnedProcess.create!(
        kind: "chat_shell_command", command: "echo hi", hostname: "worker-1", started_at: Time.current
      )
      command = build_command(spawned_process: spawned_process, finished_at: Time.current, outcome: "killed")

      expect(command.cancellable?).to eq(false)
    end

    context "in a Local Mode chat" do
      let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "local") }

      it "is false while no local_tool_call has been attached yet" do
        expect(build_command.cancellable?).to eq(false)
      end

      it "is true once a dispatched local_tool_call is attached" do
        session = LocalDaemonSession.create!(chat_session: chat_session, user: user)
        call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat_session, tool_use_id: "x", tool_name: "run_command", state: "dispatched")

        expect(build_command(local_tool_call: call).cancellable?).to eq(true)
      end

      it "is false once the local_tool_call has completed" do
        session = LocalDaemonSession.create!(chat_session: chat_session, user: user)
        call = LocalToolCall.create!(local_daemon_session: session, chat_session: chat_session, tool_use_id: "x", tool_name: "run_command", state: "completed")

        expect(build_command(local_tool_call: call).cancellable?).to eq(false)
      end
    end
  end

  describe "#as_command_json" do
    it "renders the shared wire shape while running" do
      command = build_command

      expect(command.as_command_json).to eq(
        id: command.id,
        chat_session_id: chat_session.id,
        command: "echo hi",
        output: nil,
        outcome: nil,
        exit_status: nil,
        started_at: command.started_at.iso8601,
        finished_at: nil,
        running: true,
        cancellable: false
      )
    end

    it "reflects a finished outcome" do
      command = build_command(finished_at: Time.current, outcome: "succeeded", output: "hi\n", exit_status: 0)

      json = command.as_command_json

      expect(json[:running]).to eq(false)
      expect(json[:outcome]).to eq("succeeded")
      expect(json[:output]).to eq("hi\n")
      expect(json[:exit_status]).to eq(0)
      expect(json[:finished_at]).to eq(command.finished_at.iso8601)
    end
  end
end
