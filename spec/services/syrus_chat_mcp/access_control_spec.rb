require "rails_helper"
require "ostruct"

RSpec.describe "SyrusChatMcp access control" do
  # Consume the first-user admin-promotion slot so subsequent users are not auto-promoted.
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server_for(*tools)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: tools,
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(tool, name, arguments = {})
    raw = server_for(tool).handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def text(response)
    response.dig(:result, :content, 0, :text)
  end

  def payload(response)
    JSON.parse(text(response), symbolize_names: true)
  end

  def expect_not_authorized(response)
    expect(response.dig(:result, :isError)).to be(true)
    expect(payload(response)).to eq(error: "not_authorized")
  end

  def other_user_job
    Factories.job(repository: Factories.repository(user: Factories.user))
  end

  it "cannot attach a repository owned by another user" do
    other_repository = Factories.repository(user: Factories.user, owner: "other", name: "private")

    response = call_tool(SyrusChatMcp::AttachRepositoryTool, "attach_repository", slug: other_repository.slug)

    expect(response.dig(:result, :isError)).to be(true)
    expect(text(response)).to include("is not configured for this user")
    expect(chat_session.attached_repositories).not_to include(other_repository)
  end

  it "cannot attach another user's Epic to a chat session" do
    epic = Factories.epic(user: Factories.user)

    attachment = chat_session.chat_attachments.build(attachable: epic)

    expect(attachment).not_to be_valid
    expect(attachment.errors[:attachable]).to include("must belong to the chat session user")
  end

  it "cannot read a job belonging to another user" do
    response = call_tool(SyrusChatMcp::ReadJobTool, "read_job", job_id: other_user_job.id)

    expect_not_authorized(response)
  end

  it "cannot read an Epic belonging to another user" do
    epic = Factories.epic(user: Factories.user)

    response = call_tool(SyrusChatMcp::ReadEpicTool, "read_epic", id: epic.id)

    expect_not_authorized(response)
  end

  it "cannot list workflows for another user's job" do
    response = call_tool(SyrusChatMcp::ListJobWorkflowsTool, "list_job_workflows", job_id: other_user_job.id)

    expect_not_authorized(response)
  end

  it "cannot read another user's workflow" do
    response = call_tool(SyrusChatMcp::ReadWorkflowTool, "read_workflow", workflow_id: other_user_job.latest_workflow.id)

    expect_not_authorized(response)
  end

  it "cannot read another user's run transcript" do
    response = call_tool(SyrusChatMcp::ReadRunTranscriptTool, "read_run_transcript", run_id: other_user_job.initial_run.id)

    expect_not_authorized(response)
  end

  it "cannot read another user's job diff" do
    response = call_tool(SyrusChatMcp::GetJobDiffTool, "get_job_diff", job_id: other_user_job.id)

    expect_not_authorized(response)
  end

  it "cannot add a tag to another user's job" do
    tag = Factories.tag(user: user)

    response = call_tool(SyrusChatMcp::AddJobTagTool, "add_job_tag", job_id: other_user_job.id, tag_id: tag.id)

    expect_not_authorized(response)
  end

  it "cannot remove a tag from another user's job" do
    tag = Factories.tag(user: user)

    response = call_tool(SyrusChatMcp::RemoveJobTagTool, "remove_job_tag", job_id: other_user_job.id, tag_id: tag.id)

    expect_not_authorized(response)
  end

  it "cannot request cancellation for another user's job" do
    response = call_tool(SyrusChatMcp::CancelJobTool, "cancel_job", job_id: other_user_job.id)

    expect_not_authorized(response)
    expect(chat_session.pending_actions).to be_empty
  end

  it "cannot request retry for another user's job" do
    response = call_tool(SyrusChatMcp::RetryJobTool, "retry_job", job_id: other_user_job.id)

    expect_not_authorized(response)
    expect(chat_session.pending_actions).to be_empty
  end

  it "cannot request rebase for another user's job" do
    response = call_tool(SyrusChatMcp::RebaseJobTool, "rebase_job", job_id: other_user_job.id)

    expect_not_authorized(response)
    expect(chat_session.pending_actions).to be_empty
  end

  it "cannot submit chat feedback for another user's job" do
    response = call_tool(SyrusChatMcp::SubmitChatFeedbackTool, "submit_chat_feedback", job_id: other_user_job.id, feedback: "Change this.")

    expect_not_authorized(response)
    expect(chat_session.pending_actions).to be_empty
  end

  it "reads PRs with the current user's GitHub credentials" do
    client = instance_double(
      GithubClient,
      pull_request: OpenStruct.new(number: 12, title: "Fix it", body: "Body", state: "open", html_url: "https://github.example/pr/12"),
      pull_request_diff: "diff --git a/file b/file\n"
    )
    expect(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)

    response = call_tool(SyrusChatMcp::ReadPrTool, "read_pr", pr_number: 12)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)[:pr]).to include(number: 12, title: "Fix it")
  end

  it "does not resolve proposal target repositories outside the current user's active repositories" do
    other_repository = Factories.repository(user: Factories.user, owner: "other", name: "private")

    response = call_tool(
      SyrusChatMcp::ProposeJobTool,
      "propose_job",
      title: "Ship a change",
      description: "Do the work.",
      repo: other_repository.slug
    )

    expect(response.dig(:result, :isError)).to be(true)
    expect(text(response)).to include("repository not found")
  end

  context "when the current user is an admin" do
    let(:user) { Factories.user(admin: true) }

    def other_user_job
      Factories.job(repository: Factories.repository(user: Factories.user))
    end

    it "can read a job belonging to another user" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::ReadJobTool, "read_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)[:job]).to include(id: job.id)
    end

    it "can read an Epic belonging to another user" do
      epic = Factories.epic(user: Factories.user)

      response = call_tool(SyrusChatMcp::ReadEpicTool, "read_epic", id: epic.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)[:epic]).to include(id: epic.id)
    end

    it "lists jobs across all users" do
      own_job = Factories.job(repository: repository, issue_number: 10)
      other_job = other_user_job

      response = call_tool(SyrusChatMcp::ListJobsTool, "list_jobs")

      expect(response.dig(:result, :isError)).to be_falsey
      listed_ids = payload(response)[:jobs].map { |j| j[:id] }
      expect(listed_ids).to include(own_job.id, other_job.id)
    end

    it "searches jobs across all users" do
      other_job = Factories.job(repository: Factories.repository(user: Factories.user), issue_number: 11, issue_title: "Admin search target")

      response = call_tool(SyrusChatMcp::SearchJobsTool, "search_jobs", query: "Admin search target")

      expect(response.dig(:result, :isError)).to be_falsey
      listed_ids = payload(response)[:results].map { |j| j[:id] }
      expect(listed_ids).to include(other_job.id)
    end

    it "lists epics across all users" do
      own_epic = Factories.epic(user: user, repository: repository)
      other_epic = Factories.epic(user: Factories.user)

      response = call_tool(SyrusChatMcp::ListEpicsTool, "list_epics")

      expect(response.dig(:result, :isError)).to be_falsey
      listed_ids = payload(response)[:epics].map { |e| e[:id] }
      expect(listed_ids).to include(own_epic.id, other_epic.id)
    end

    it "lists repositories across all users" do
      other_repository = Factories.repository(user: Factories.user)

      response = call_tool(SyrusChatMcp::ListRepositoriesTool, "list_repositories")

      expect(response.dig(:result, :isError)).to be_falsey
      listed_ids = payload(response)[:repositories].map { |r| r[:id] }
      expect(listed_ids).to include(repository.id, other_repository.id)
    end

    it "can list workflows for another user's job" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::ListJobWorkflowsTool, "list_job_workflows", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
    end

    it "can read another user's workflow" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::ReadWorkflowTool, "read_workflow", workflow_id: job.latest_workflow.id)

      expect(response.dig(:result, :isError)).to be_falsey
    end

    it "can read another user's run transcript" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::ReadRunTranscriptTool, "read_run_transcript", run_id: job.initial_run.id)

      expect(response.dig(:result, :isError)).to be_falsey
    end

    it "can cancel another user's job" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::CancelJobTool, "cancel_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
    end

    it "can update another user's job" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::UpdateJobTool, "update_job", job_id: job.id, title: "Admin updated title")

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)[:title]).to eq("Admin updated title")
    end

    it "can set priority on another user's job" do
      job = other_user_job

      response = call_tool(SyrusChatMcp::SetJobPriorityTool, "set_job_priority", job_id: job.id, priority: "high")

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)[:new_priority]).to eq("high")
    end

    it "non-admin still gets not_authorized on another user's job" do
      non_admin = Factories.user(admin: false)
      non_admin_chat = ChatSession.create!(user: non_admin, repository: Factories.repository(user: non_admin))
      job = other_user_job

      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ SyrusChatMcp::ReadJobTool ],
        server_context: { chat_session: non_admin_chat }
      )
      raw = server.handle_json({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "read_job", arguments: { job_id: job.id } }
      }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be(true)
      expect(payload(response)).to eq(error: "not_authorized")
    end
  end
end
