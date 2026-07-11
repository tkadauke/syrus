require "rails_helper"

RSpec.describe "Local Mode MCP tools" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "local") }
  let(:daemon_session) do
    chat_session.create_local_daemon_session!(
      user: user,
      auth_token: "tok",
      connected_at: Time.current
    )
  end

  def server_with(*tools)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: tools,
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(server, name, arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def stub_dispatch(tool_name, arguments, result: nil, error: nil)
    call = instance_double(LocalToolCall)
    outcome = result ? { result: result } : { error: error }
    allow(daemon_session).to receive(:dispatch_tool_call!).with(tool_name, arguments).and_return(call)
    allow(call).to receive(:wait_for_result).and_return(outcome)
  end

  shared_examples "disconnected daemon" do |tool_name, arguments = {}|
    it "returns an error when no daemon session exists" do
      server = server_with(described_class)
      response = call_tool(server, tool_name, arguments)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not connected")
    end

    it "returns an error when the daemon session is not connected" do
      chat_session.create_local_daemon_session!(user: user, auth_token: "tok")
      server = server_with(described_class)

      response = call_tool(server, tool_name, arguments)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not connected")
    end
  end

  describe SyrusChatMcp::ReadFileTool do
    include_examples "disconnected daemon", "read_file", { path: "README.md" }

    it "dispatches read_file to the daemon and returns the result" do
      stub_dispatch("read_file", { path: "README.md" }, result: { content: "# Project" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "read_file", { path: "README.md" })

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:content]).to eq("# Project")
    end
  end

  describe SyrusChatMcp::WriteFileTool do
    include_examples "disconnected daemon", "write_file", { path: "foo.rb", content: "# hello" }

    it "dispatches write_file to the daemon" do
      stub_dispatch("write_file", { path: "app/foo.rb", content: "class Foo; end" }, result: { written: true })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "write_file", { path: "app/foo.rb", content: "class Foo; end" })

      expect(response.dig(:result, :isError)).to be_falsey
    end
  end

  describe SyrusChatMcp::ListFilesTool do
    include_examples "disconnected daemon", "list_files", {}

    it "dispatches list_files to the daemon with a default path" do
      stub_dispatch("list_files", { path: "." }, result: { files: %w[README.md Gemfile] })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "list_files", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:files]).to include("README.md")
    end
  end

  describe SyrusChatMcp::RunCommandTool do
    include_examples "disconnected daemon", "run_command", { command: "echo hi" }

    it "dispatches run_command to the daemon" do
      stub_dispatch("run_command", { command: "bundle exec rspec" }, result: { exit_code: 0, output: "1 example, 0 failures" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "run_command", { command: "bundle exec rspec" })

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:exit_code]).to eq(0)
    end

    it "propagates daemon-side errors" do
      stub_dispatch("run_command", { command: "bad-cmd" }, error: "command not found")
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "run_command", { command: "bad-cmd" })

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("command not found")
    end
  end

  describe SyrusChatMcp::GitDiffTool do
    include_examples "disconnected daemon", "git_diff", {}

    it "dispatches git_diff to the daemon" do
      stub_dispatch("git_diff", {}, result: { diff: "diff --git a/foo.rb..." })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "git_diff", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:diff]).to start_with("diff")
    end
  end

  describe SyrusChatMcp::GitStatusTool do
    include_examples "disconnected daemon", "git_status", {}

    it "dispatches git_status to the daemon" do
      stub_dispatch("git_status", {}, result: { status: "On branch main\nnothing to commit" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "git_status", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:status]).to include("On branch")
    end
  end

  describe SyrusChatMcp::OpenInLocalModeTool do
    let(:repository) { Factories.repository(user: user) }

    before { allow(Feature).to receive(:local_mode_enabled?).and_return(true) }

    it "takes over an implemented job and enters coding state" do
      job = Factories.job_record(repository: repository, state: "implemented", branch_name: "syrus/job-99")
      server = server_with(described_class)

      response = call_tool(server, "open_in_local_mode", job_id: job.id)
      result = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

      expect(result).to include(job_id: job.id, job_state: "coding", branch_name: "syrus/job-99")
      expect(job.reload).to be_coding
      expect(job.linked_chat_id).to eq(chat_session.id)
    end

    it "unapproves an approved job before entering local mode" do
      job = Factories.job_record(repository: repository, state: "approved", branch_name: "syrus/job-88")
      allow(Job::ApprovalPropagator).to receive(:dismiss).and_return(double(message: nil))
      server = server_with(described_class)

      call_tool(server, "open_in_local_mode", job_id: job.id)

      expect(job.reload).to be_coding
    end

    it "rejects jobs not in implemented or approved state" do
      job = Factories.job_record(repository: repository, state: "running")
      server = server_with(described_class)

      response = call_tool(server, "open_in_local_mode", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("implemented or approved")
    end

    it "rejects a job already linked to another chat" do
      other_chat = ChatSession.create!(user: user, mode: "local")
      job = Factories.job_record(repository: repository, state: "implemented")
      job.update_columns(linked_chat_id: other_chat.id, state: "coding")
      server = server_with(described_class)

      response = call_tool(server, "open_in_local_mode", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("already linked")
    end
  end

  describe SyrusChatMcp::CancelLocalModeTool do
    let(:repository) { Factories.repository(user: user) }

    it "returns a taken-over job (with pr) to implemented state" do
      job = Factories.job_record(repository: repository, state: "implemented", branch_name: "syrus/job-1", pr_number: 77)
      job.update_columns(linked_chat_id: chat_session.id, state: "coding")
      server = server_with(described_class)

      response = call_tool(server, "cancel_local_mode", job_id: job.id)
      result = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

      expect(result).to include(job_id: job.id, job_state: "implemented")
      expect(job.reload).to be_implemented
      expect(job.linked_chat_id).to be_nil
    end

    it "closes a new coding job with no pr" do
      job = Factories.job_record(repository: repository, state: "running", kind: "direct", issue_number: nil)
      job.update_columns(linked_chat_id: chat_session.id, state: "coding", pr_number: nil)
      server = server_with(described_class)

      call_tool(server, "cancel_local_mode", job_id: job.id)

      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("local_mode_cancelled")
      expect(job.linked_chat_id).to be_nil
    end

    it "rejects when the job is not in coding state" do
      job = Factories.job_record(repository: repository, state: "implemented")
      server = server_with(described_class)

      response = call_tool(server, "cancel_local_mode", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not in coding state")
    end

    it "rejects when the job is linked to a different chat" do
      other_chat = ChatSession.create!(user: user, mode: "local")
      job = Factories.job_record(repository: repository, state: "implemented")
      job.update_columns(linked_chat_id: other_chat.id, state: "coding")
      server = server_with(described_class)

      response = call_tool(server, "cancel_local_mode", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not linked to this chat session")
    end
  end

  describe SyrusChatMcp::CompleteImplementStepTool do
    let(:repository) { Factories.repository(user: user) }

    before { allow(StepDispatcher).to receive(:start_workflow) }

    it "releases the lock and triggers a local_mode_handoff workflow for a job with a pr" do
      job = Factories.job_record(repository: repository, state: "implemented", branch_name: "syrus/job-2", pr_number: 10)
      job.update_columns(linked_chat_id: chat_session.id, state: "coding")
      server = server_with(described_class)

      expect(Workflows::LocalModeHandoff).to receive(:instantiate).and_call_original

      response = call_tool(server, "complete_implement_step", job_id: job.id)
      result = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

      expect(result[:job_id]).to eq(job.id)
      expect(job.reload.linked_chat_id).to be_nil
      expect(StepDispatcher).to have_received(:start_workflow)
    end

    it "sets branch_name on new jobs without a pr" do
      job = Factories.job_record(repository: repository, state: "running", kind: "direct", issue_number: nil, branch_name: nil)
      job.update_columns(linked_chat_id: chat_session.id, state: "coding", pr_number: nil)
      server = server_with(described_class)

      call_tool(server, "complete_implement_step", job_id: job.id, branch_name: "syrus/my-feature")

      expect(job.reload.branch_name).to eq("syrus/my-feature")
    end

    it "requires branch_name for new jobs without a pr" do
      job = Factories.job_record(repository: repository, state: "running", kind: "direct", issue_number: nil)
      job.update_columns(linked_chat_id: chat_session.id, state: "coding", pr_number: nil)
      server = server_with(described_class)

      response = call_tool(server, "complete_implement_step", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("branch_name is required")
      expect(job.reload).to be_coding
    end

    it "rejects when the job is not in coding state" do
      job = Factories.job_record(repository: repository, state: "implemented")
      server = server_with(described_class)

      response = call_tool(server, "complete_implement_step", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not in coding state")
    end

    it "rejects when the job is linked to a different chat" do
      other_chat = ChatSession.create!(user: user, mode: "local")
      job = Factories.job_record(repository: repository, state: "implemented", pr_number: 99)
      job.update_columns(linked_chat_id: other_chat.id, state: "coding")
      server = server_with(described_class)

      response = call_tool(server, "complete_implement_step", job_id: job.id)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not linked to this chat session")
    end
  end

  describe SyrusChatMcp::CreateCodingJobTool do
    let(:repository) { Factories.repository(user: user) }

    before { chat_session.chat_attachments.create!(attachable: repository) }

    it "creates a direct job in coding state linked to the chat" do
      server = server_with(described_class)

      response = call_tool(server, "create_coding_job", title: "Fix the widget", body: "The widget is broken.")
      result = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

      job = Job.find(result[:job_id])
      expect(job).to be_coding
      expect(job.linked_chat_id).to eq(chat_session.id)
      expect(job.kind).to eq("direct")
      expect(job.issue_title).to eq("Fix the widget")
    end

    it "uses an explicit repository_id when provided" do
      other_repo = Factories.repository(user: user)
      server = server_with(described_class)

      response = call_tool(server, "create_coding_job", title: "Fix it", body: "Break it.", repository_id: other_repo.id)
      result = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

      job = Job.find(result[:job_id])
      expect(job.repository_id).to eq(other_repo.id)
    end

    it "returns an error when no repository is found" do
      chat_session.chat_attachments.destroy_all
      server = server_with(described_class)

      response = call_tool(server, "create_coding_job", title: "Fix it", body: "Break it.")

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("Repository not found")
    end
  end
end
