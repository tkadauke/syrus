require "rails_helper"
require "tmpdir"

RSpec.describe ChatShellCommandJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) do
    ChatSession.create!(user: user, repository: repository, mode: "coding", coding_checkout_branch: "syrus-chat-1")
  end

  before do
    @data_root = Dir.mktmpdir("syrus-chat-shell-cmd")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(@data_root) if @data_root
  end

  def make_checkout_path
    path = ChatWorkspace.repo_path_for(chat_session, repository)
    FileUtils.mkdir_p(path.join(".git").to_s)
    path
  end

  def build_result(exit_status: 0, operator_killed: false)
    exit_status = nil if operator_killed
    ProcessRunner::Result.new(
      exit_status: exit_status, timed_out: false, stopped: false, silent_timed_out: false,
      operator_killed: operator_killed, aliveness_failed: false, duration_s: 0.5,
      spawned_process_id: nil
    )
  end

  # Simulates ProcessRunner#run firing its callbacks (output chunks, then the
  # spawned_process registration) before returning `result` -- the job only
  # cares about the callbacks it was handed, not ProcessRunner's internals.
  # `captured_kwargs`, if given a Hash, is filled in with the args ChatShellCommandJob
  # passed to ProcessRunner.new so the caller can assert on them.
  def stub_process_runner(result:, chunks: [], spawned_process: nil, captured_kwargs: nil)
    runner = instance_double(ProcessRunner)
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured_kwargs.replace(kwargs) if captured_kwargs.is_a?(Hash)
      allow(runner).to receive(:run) do
        chunks.each { |chunk| kwargs[:on_output_chunk]&.call(chunk) }
        kwargs[:on_spawned_process]&.call(spawned_process) if spawned_process
        result
      end
      runner
    end
    runner
  end

  def create_command(command: "echo hi")
    chat_session.chat_shell_commands.create!(user: user, command: command, started_at: Time.current)
  end

  it "runs on the chat queue" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "records an error outcome when the chat has no attached repository" do
    orphan_chat = ChatSession.create!(user: user, mode: "coding", coding_checkout_branch: "syrus-chat-orphan")
    command = orphan_chat.chat_shell_commands.create!(user: user, command: "echo hi", started_at: Time.current)
    expect(ProcessRunner).not_to receive(:new)

    expect {
      described_class.perform_now(command.id)
    }.to have_enqueued_job(ChatTurnJob)

    expect(command.reload.outcome).to eq("error")
    expect(command.output).to include("No repository attached")
  end

  it "records an error outcome when the checkout directory does not exist" do
    command = create_command
    expect(ProcessRunner).not_to receive(:new)

    described_class.perform_now(command.id)

    expect(command.reload.outcome).to eq("error")
    expect(command.output).to include("Coding checkout not found")
    expect(command.finished_at).to be_present
  end

  it "runs the command in the persistent coding checkout with a scrubbed env and no wall-clock timeout" do
    path = make_checkout_path
    command = create_command(command: "echo hi")
    spawned_process = SpawnedProcess.create!(
      kind: "chat_shell_command", command: "echo hi", hostname: "worker-1", started_at: Time.current
    )
    captured_kwargs = {}
    stub_process_runner(result: build_result, chunks: [ "hi\n" ], spawned_process: spawned_process, captured_kwargs: captured_kwargs)

    described_class.perform_now(command.id)

    expect(captured_kwargs).to include(
      command: [ "bash", "-c", "echo hi" ],
      chdir: path,
      timeout: described_class::MAX_RUNTIME_SECONDS,
      kind: "chat_shell_command",
      chat_session: chat_session
    )
    command.reload
    expect(command.outcome).to eq("succeeded")
    expect(command.output).to eq("hi\n")
    expect(command.exit_status).to eq(0)
    expect(command.spawned_process_id).to eq(spawned_process.id)
    expect(command.finished_at).to be_present
  end

  it "records a failed outcome for a non-zero exit status" do
    make_checkout_path
    command = create_command(command: "exit 1")
    stub_process_runner(result: build_result(exit_status: 1))

    described_class.perform_now(command.id)

    expect(command.reload.outcome).to eq("failed")
    expect(command.exit_status).to eq(1)
  end

  it "records a killed outcome when the operator cancels the command" do
    make_checkout_path
    command = create_command(command: "sleep 100")
    stub_process_runner(result: build_result(operator_killed: true))

    described_class.perform_now(command.id)

    expect(command.reload.outcome).to eq("killed")
  end

  it "caps captured output via ChatShellCommand.append_capped" do
    make_checkout_path
    command = create_command
    huge = "a" * (ChatShellCommand::MAX_OUTPUT_BYTES + 100)
    stub_process_runner(result: build_result, chunks: [ huge ])

    described_class.perform_now(command.id)

    command.reload
    expect(command.output.bytesize).to be > ChatShellCommand::MAX_OUTPUT_BYTES
    expect(command.output).to end_with(ChatShellCommand::TRUNCATION_NOTICE)
  end

  it "always posts a distinct chat message and triggers a normal agent turn on completion" do
    make_checkout_path
    command = create_command
    stub_process_runner(result: build_result)

    expect {
      described_class.perform_now(command.id)
    }.to have_enqueued_job(ChatTurnJob).with(chat_session.id, kind_of(Integer))

    message = chat_session.messages.order(:id).last
    expect(message.role).to eq("user")
    expect(message.content["chat_shell_command_id"]).to eq(command.id)
    expect(chat_session.reload.turn_in_flight?).to eq(true)
  end

  it "sets an internal_prompt describing the command and output for the agent turn, leaving the display text blank" do
    make_checkout_path
    command = create_command(command: "echo hi")
    stub_process_runner(result: build_result, chunks: [ "hi\n" ])

    described_class.perform_now(command.id)

    message = chat_session.messages.order(:id).last
    expect(message.content["text"]).to eq("")
    expect(message.content["internal_prompt"]).to include("echo hi").and include("hi\n").and include("succeeded")
  end

  it "finalizes the command as an error and still posts a chat message when the run raises" do
    make_checkout_path
    command = create_command
    allow(ProcessRunner).to receive(:new).and_raise(StandardError, "boom")
    allow(Rails.logger).to receive(:error)

    expect {
      described_class.perform_now(command.id)
    }.to have_enqueued_job(ChatTurnJob)

    expect(command.reload.outcome).to eq("error")
    expect(command.output).to include("boom")
  end

  it "discards instead of raising when the ChatShellCommand no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  describe "Local Mode" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "local") }

    def connected_daemon_session
      session = LocalDaemonSession.create!(chat_session: chat_session, user: user)
      session.mark_connected!(repo: "acme/widgets", branch: "main")
      session
    end

    it "records an error outcome when no daemon is connected" do
      command = create_command
      expect(ProcessRunner).not_to receive(:new)

      described_class.perform_now(command.id)

      expect(command.reload.outcome).to eq("error")
      expect(command.output).to include("Local daemon not connected")
    end

    it "dispatches the command over the tunnel and records the daemon's result" do
      connected_daemon_session
      command = create_command(command: "echo hi")

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).complete!(result: { "stdout" => "hi\n", "stderr" => "", "exit_code" => 0 })
      end

      expect {
        described_class.perform_now(command.id)
      }.to have_enqueued_job(ChatTurnJob)

      command.reload
      expect(command.outcome).to eq("succeeded")
      expect(command.output).to eq("hi\n")
      expect(command.exit_status).to eq(0)
      expect(command.local_tool_call).to be_present
    end

    it "records a killed outcome when the daemon reports the command was cancelled" do
      connected_daemon_session
      command = create_command(command: "sleep 100")

      Thread.new do
        sleep 0.05
        LocalToolCall.find_by(chat_session: chat_session).complete!(result: { "stdout" => "", "stderr" => "", "exit_code" => -1, "killed" => true })
      end

      described_class.perform_now(command.id)

      expect(command.reload.outcome).to eq("killed")
    end
  end
end
