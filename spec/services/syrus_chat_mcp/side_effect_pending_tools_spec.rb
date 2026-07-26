require "rails_helper"

RSpec.describe "SyrusChatMcp side-effect pending tools" do
  include ActiveJob::TestHelper

  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ReopenJobTool,
        SyrusChatMcp::FireScheduledTaskNowTool,
        SyrusChatMcp::CreateRepoDocumentTool,
        SyrusChatMcp::DeleteRepoDocumentTool,
        SyrusChatMcp::PollJobFeedbackTool,
        SyrusChatMcp::CheckJobMergeabilityTool,
        SyrusChatMcp::DelegateIssueTool,
        SyrusChatMcp::PauseLandingQueueTool,
        SyrusChatMcp::ResumeLandingQueueTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def text(response)
    response.dig(:result, :content, 0, :text)
  end

  def scheduled_task(attrs = {})
    repository.scheduled_tasks.create!({
      user: user,
      kind: "cron",
      name: "Daily review",
      prompt: "Review the repository.",
      cron_expression: "0 9 * * *",
      pr_pileup_policy: "skip"
    }.merge(attrs))
  end

  def pending_action_from(response)
    chat_session.pending_actions.find(payload(response).fetch(:pending_confirmation_id))
  end

  it "creates and confirms a reopen_job action" do
    job = Factories.job_record(repository: repository, state: "closed", closure_reason: "cancelled", finished_at: 1.hour.ago)

    action = pending_action_from(call_tool("reopen_job", job_id: job.id))

    expect(action).to have_attributes(action: "reopen_job", payload: { "job_id" => job.id })
    expect(action.confirm!).to be true
    expect(job.reload).to be_triaging
  end

  it "creates and confirms a fire_scheduled_task_now action" do
    task = scheduled_task
    result = ScheduledTaskFire::Result.new(job: Factories.job_record(user: user, repository: repository, kind: "cron", scheduled_task: task, issue_number: nil), skipped: false, reason: nil)
    service = instance_double(ScheduledTaskFire, call: result)
    allow(ScheduledTaskFire).to receive(:new).with(task).and_return(service)

    action = pending_action_from(call_tool("fire_scheduled_task_now", scheduled_task_id: task.id))

    expect(action).to have_attributes(action: "fire_scheduled_task_now", payload: { "scheduled_task_id" => task.id })
    expect(action.confirm!).to be true
    expect(ScheduledTaskFire).to have_received(:new).with(task)
  end

  it "creates and confirms a create_repo_document action" do
    response = call_tool("create_repo_document", repository_id: repository.id, title: "Runbook", body: "Ship safely.")
    action = pending_action_from(response)

    expect(action).to have_attributes(
      action: "create_repo_document",
      payload: { "repository_id" => repository.id, "title" => "Runbook", "body" => "Ship safely." }
    )

    expect {
      expect(action.confirm!).to be true
    }.to change { repository.repository_documents.count }.by(1)

    document = repository.repository_documents.last
    expect(document).to have_attributes(user: user, title: "Runbook", kind: "file")
    expect(document.file.download).to eq("Ship safely.")
  end

  it "creates and confirms a delete_repo_document action" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Old notes",
      google_docs_url: "https://docs.google.com/document/d/old/edit"
    )

    action = pending_action_from(call_tool("delete_repo_document", document_id: document.id))

    expect(action).to have_attributes(action: "delete_repo_document", payload: { "document_id" => document.id, "title" => "Old notes" })
    expect(action.confirm!).to be true
    expect(Document.exists?(document.id)).to be false
  end

  it "creates and confirms a poll_job_feedback action" do
    job = Factories.job_record(repository: repository, state: "implemented", pr_number: 42)

    action = pending_action_from(call_tool("poll_job_feedback", job_id: job.id))

    expect(action).to have_attributes(action: "poll_job_feedback", payload: { "job_id" => job.id })
    expect {
      expect(action.confirm!).to be true
    }.to have_enqueued_job(PollPullRequestJob).with(job.id, manual: true)
  end

  it "creates and confirms a check_job_mergeability action" do
    job = Factories.job_record(repository: repository, pr_number: 42)

    action = pending_action_from(call_tool("check_job_mergeability", job_id: job.id))

    expect(action).to have_attributes(action: "check_job_mergeability", payload: { "job_id" => job.id })
    expect {
      expect(action.confirm!).to be true
    }.to have_enqueued_job(PollRebaseJob).with(job.id, bypass_cache: true)
  end

  it "creates and confirms a delegate_issue action" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:add_label_to_issue)

    action = pending_action_from(call_tool("delegate_issue", repository_id: repository.id, issue_number: 7))

    expect(action).to have_attributes(action: "delegate_issue", payload: { "repository_id" => repository.id, "issue_number" => 7 })
    expect(action.confirm!).to be true
    expect(client).to have_received(:add_label_to_issue).with("acme/widgets", 7, repository.trigger_label)
  end

  it "creates and confirms pause and resume landing queue actions" do
    pause_action = pending_action_from(call_tool("pause_landing_queue"))
    expect(pause_action).to have_attributes(action: "pause_landing_queue", payload: {})
    expect(pause_action.confirm!).to be true
    expect(user.reload.landing_paused).to be true

    resume_action = pending_action_from(call_tool("resume_landing_queue"))
    expect(resume_action).to have_attributes(action: "resume_landing_queue", payload: {})
    expect {
      expect(resume_action.confirm!).to be true
    }.to have_enqueued_job(LandingQueueProcessorJob)
    expect(user.reload.landing_paused).to be false
  end

  it "creates and confirms pause and resume landing queue actions without an attached repository" do
    repositoryless_chat_session = ChatSession.create!(user: user)
    allow(self).to receive(:chat_session).and_return(repositoryless_chat_session)

    pause_action = pending_action_from(call_tool("pause_landing_queue"))
    expect(pause_action).to have_attributes(action: "pause_landing_queue", payload: {}, repository: nil)
    expect(pause_action.confirm!).to be true
    expect(user.reload.landing_paused).to be true

    resume_action = pending_action_from(call_tool("resume_landing_queue"))
    expect(resume_action).to have_attributes(action: "resume_landing_queue", payload: {}, repository: nil)
    expect {
      expect(resume_action.confirm!).to be true
    }.to have_enqueued_job(LandingQueueProcessorJob)
    expect(user.reload.landing_paused).to be false
  end

  it "rejects cross-user jobs at tool call time" do
    other_user = Factories.user
    other_job = Factories.job_record(user: other_user, repository: Factories.repository(user: other_user))

    %w[reopen_job poll_job_feedback check_job_mergeability].each do |tool_name|
      response = call_tool(tool_name, job_id: other_job.id)

      expect(response.dig(:result, :isError)).to be true
      expect(text(response)).to include("job not found")
    end
  end

  it "rejects cross-user scheduled tasks at tool call time" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    other_task = other_repo.scheduled_tasks.create!(
      user: other_user,
      kind: "cron",
      name: "Other task",
      prompt: "Ignore this.",
      cron_expression: "0 8 * * *",
      pr_pileup_policy: "skip"
    )

    response = call_tool("fire_scheduled_task_now", scheduled_task_id: other_task.id)

    expect(response.dig(:result, :isError)).to be true
    expect(text(response)).to include("scheduled task not found")
  end

  it "rejects cross-user repositories at tool call time" do
    other_repository = Factories.repository(user: Factories.user)

    %w[create_repo_document delegate_issue].each do |tool_name|
      args = tool_name == "create_repo_document" ? { repository_id: other_repository.id, title: "Nope", body: "Nope" } : { repository_id: other_repository.id, issue_number: 1 }
      response = call_tool(tool_name, args)

      expect(response.dig(:result, :isError)).to be true
      expect(text(response)).to include("repository not found")
    end
  end

  it "rejects cross-user documents at tool call time" do
    other_user = Factories.user
    other_repository = Factories.repository(user: other_user)
    other_document = other_repository.repository_documents.create!(
      user: other_user,
      kind: "google_doc",
      title: "Other notes",
      google_docs_url: "https://docs.google.com/document/d/other/edit"
    )

    response = call_tool("delete_repo_document", document_id: other_document.id)

    expect(response.dig(:result, :isError)).to be true
    expect(text(response)).to include("document not found")
  end
end
