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
  end
end
