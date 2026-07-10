require "rails_helper"

RSpec.describe SyrusChatMcp::CompleteImplementStepTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user) }

  let(:job) do
    Factories.job_record(
      user: user, repository: repository, state: "coding",
      linked_chat_id: chat_session.id, branch_name: "syrus/my-job-1"
    )
  end

  let(:workspace_path) { Pathname.new("/tmp/fake-coding-workspace/#{chat_session.id}") }

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc("tools/call", params: { name: "complete_implement_step", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def stub_workspace(dirty: false)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, job.repository).and_return(workspace_path)
    allow(workspace_path).to receive(:directory?).and_return(true)

    git_runner = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(git_runner)

    if dirty
      allow(git_runner).to receive(:run).with("status", "--porcelain", chdir: workspace_path.to_s)
                                        .and_return(" M file.rb\n")
      allow(git_runner).to receive(:run).with("add", "-A", chdir: workspace_path.to_s)
      allow(git_runner).to receive(:run).with("commit", "-m", anything, chdir: workspace_path.to_s)
    else
      allow(git_runner).to receive(:run).with("status", "--porcelain", chdir: workspace_path.to_s)
                                        .and_return("")
    end

    token = "fake-token"
    github_client = instance_double(GithubClient, access_token: token)
    allow(GithubClient).to receive(:for).with(repository: job.repository, user: user).and_return(github_client)
    authenticated_url = repository.authenticated_push_url(token)
    allow(git_runner).to receive(:run).with("push", authenticated_url, "HEAD:#{job.branch_name}", chdir: workspace_path.to_s)

    git_runner
  end

  context "when coding_mode feature flag is off" do
    it "returns an error" do
      response = call_tool(job_id: job.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("Coding Mode is not enabled")
    end
  end

  context "when coding_mode feature flag is on" do
    before { enable_coding_mode! }

    it "returns an error for an unknown job id" do
      response = call_tool(job_id: 999_999)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("job not found")
    end

    it "returns an error when the job is not in coding state" do
      job.update!(state: "implemented")
      stub_workspace

      response = call_tool(job_id: job.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not in coding state")
    end

    it "returns an error when the chat session does not own the job" do
      other_chat = ChatSession.create!(user: user)
      job.update!(linked_chat_id: other_chat.id)
      stub_workspace

      response = call_tool(job_id: job.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("does not own job")
    end

    it "returns an error when the coding workspace directory does not exist" do
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, job.repository).and_return(workspace_path)
      allow(workspace_path).to receive(:directory?).and_return(false)

      response = call_tool(job_id: job.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("coding workspace not found")
    end

    context "with a clean workspace (no uncommitted changes)" do
      before { stub_workspace(dirty: false) }

      it "pushes the branch and transitions the job to implemented" do
        call_tool(job_id: job.id)

        expect(job.reload).to be_implemented
      end

      it "preserves linked_chat_id for grader routing" do
        call_tool(job_id: job.id)

        expect(job.reload.linked_chat_id).to eq(chat_session.id)
      end

      it "creates a coding_handoff workflow" do
        expect {
          call_tool(job_id: job.id)
        }.to change { job.workflows.where(trigger_kind: "coding_handoff").count }.by(1)
      end

      it "returns a success message with workflow_id" do
        response = call_tool(job_id: job.id)

        expect(response[:result][:isError]).to be_falsey
        payload = response_payload(response)
        expect(payload[:message]).to include("handed off to Syrus for grading")
        expect(payload[:workflow_id]).to be_present
        expect(payload[:job_state]).to eq("implemented")
      end
    end

    context "with a dirty workspace (uncommitted changes)" do
      it "commits changes before pushing" do
        git_runner = stub_workspace(dirty: true)

        call_tool(job_id: job.id)

        expect(git_runner).to have_received(:run).with("add", "-A", chdir: workspace_path.to_s)
        expect(git_runner).to have_received(:run).with(
          "commit", "-m", "Coding session: finish implementation", chdir: workspace_path.to_s
        )
      end

      it "uses a custom commit message when provided" do
        git_runner = stub_workspace(dirty: true)
        allow(git_runner).to receive(:run).with("commit", "-m", "My custom message", chdir: workspace_path.to_s)

        call_tool(job_id: job.id, commit_message: "My custom message")

        expect(git_runner).to have_received(:run).with(
          "commit", "-m", "My custom message", chdir: workspace_path.to_s
        )
      end
    end

    context "when there is a held initial workflow" do
      before { stub_workspace(dirty: false) }

      it "cancels the held initial workflow" do
        initial_workflow = Workflow.create!(job: job, trigger_kind: "initial")
        Step.create!(workflow: initial_workflow, kind: "implement", position: 0)

        call_tool(job_id: job.id)

        expect(initial_workflow.reload).to be_cancelled
      end

      it "does not cancel non-initial queued workflows" do
        pr_comment_workflow = Workflow.create!(job: job, trigger_kind: "pr_comment")
        Step.create!(workflow: pr_comment_workflow, kind: "respond", position: 0)

        call_tool(job_id: job.id)

        expect(pr_comment_workflow.reload).to be_queued
      end
    end

    context "when git push fails" do
      it "returns a tool error" do
        allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, job.repository).and_return(workspace_path)
        allow(workspace_path).to receive(:directory?).and_return(true)

        git_runner = instance_double(GitRunner)
        allow(GitRunner).to receive(:new).and_return(git_runner)
        allow(git_runner).to receive(:run).with("status", "--porcelain", chdir: workspace_path.to_s)
                                          .and_return("")

        token = "fake-token"
        github_client = instance_double(GithubClient, access_token: token)
        allow(GithubClient).to receive(:for).with(repository: job.repository, user: user).and_return(github_client)
        authenticated_url = repository.authenticated_push_url(token)
        allow(git_runner).to receive(:run).with("push", authenticated_url, "HEAD:#{job.branch_name}", chdir: workspace_path.to_s)
                                          .and_raise(GitRunner::GitError.new(["push"], 1, "remote: Permission denied"))

        response = call_tool(job_id: job.id)

        expect(response[:result][:isError]).to be(true)
        expect(response[:result][:content].first[:text]).to include("Git operation failed")
        expect(job.reload).to be_coding
      end
    end
  end
end
