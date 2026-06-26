require "rails_helper"
require "ostruct"

RSpec.describe "SyrusChatMcp access control" do
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
end
