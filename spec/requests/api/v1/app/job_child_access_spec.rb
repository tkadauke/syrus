require "rails_helper"

RSpec.describe "App API job child access", type: :request do
  let(:owner) { Factories.user }
  let(:writer) { Factories.user }
  let(:reader) { Factories.user }
  let(:stranger) { Factories.user }
  let(:repo) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42, issue_title: "Shared job") }

  before do
    repo.repository_memberships.create!(user: writer, role: "write")
    repo.repository_memberships.create!(user: reader, role: "read")
    allow(AppEvents).to receive(:broadcast)
  end

  def parse_body = JSON.parse(response.body)

  def as_actor(actor)
    delete "/session"
    sign_in_as(actor)
    yield
  end

  def expect_statuses(statuses, &request)
    statuses.each do |actor_name, expected_status|
      as_actor(public_send(actor_name), &request)
      expect(response).to have_http_status(expected_status), "#{actor_name} expected #{expected_status}, got #{response.status}: #{response.body}"
    end
  end

  def attach_text_file(job_record)
    attachment = job_record.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(io: StringIO.new("hello"), filename: "notes.txt", content_type: "text/plain")
    attachment.save!
    attachment
  end

  it "lets repository collaborators read attachment content but only write members mutate attachments" do
    attachment = attach_text_file(job)

    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      get "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}/content"
    end

    expect_statuses(owner: :ok, writer: :ok, reader: :forbidden, stranger: :not_found) do
      post "/api/v1/app/jobs/#{job.id}/attachments",
           params: { job_attachment: { google_doc_url: "https://docs.google.com/document/d/context/edit" } },
           as: :json
    end
  end

  it "lets repository collaborators read previews but only write members start them" do
    job.update_columns(state: "implemented")
    selection = App::PreviewProjects::Result.new(choices: [
      App::PreviewProjects::Choice.new(id: "repo", label: "Repository", path: "", owner_config_path: ".syrus.yml")
    ], unavailable_reason: nil)
    allow(App::PreviewProjects).to receive(:for_job).with(job).and_return(selection)

    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      get "/api/v1/app/jobs/#{job.id}/preview", as: :json
    end

    expect_statuses(owner: :created, writer: :created, reader: :forbidden, stranger: :not_found) do
      PreviewEnvironment.where(job: job).delete_all
      post "/api/v1/app/jobs/#{job.id}/preview", as: :json
    end
  end

  it "lets repository collaborators read deploy state but only write members enqueue deploys" do
    job.update_columns(state: "approved")
    Workflow.create!(job: job, trigger_kind: "deploy", state: "queued")
    allow(WorkUnits::Launcher).to receive(:instantiate) do
      Workflow.create!(job: job, trigger_kind: "deploy", state: "queued")
    end
    allow(WorkUnits::Launcher).to receive(:start!) do |workflow|
      WorkUnits::Launcher::Result.new(workflow: workflow, run: true, intent: nil, work_unit: nil, status: "started", reason: nil, gate_result: nil)
    end

    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      get "/api/v1/app/jobs/#{job.id}/deploy", as: :json
    end

    expect_statuses(owner: :created, writer: :created, reader: :forbidden, stranger: :not_found) do
      job.workflows.where(trigger_kind: "deploy").delete_all
      post "/api/v1/app/jobs/#{job.id}/deploy", as: :json
    end
  end

  it "lets repository collaborators read pending feedback but only write members action it" do
    job.update_columns(state: "implemented", pr_number: 7)
    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 10_001,
      github_handle: "reviewer",
      attributed_to: "external",
      actionable: true,
      body: "Please add tests",
      comment_created_at: 1.hour.ago
    )

    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      get "/api/v1/app/jobs/#{job.id}/pending_feedback", as: :json
    end

    expect_statuses(owner: :ok, writer: :ok, reader: :forbidden, stranger: :not_found) do
      comment = PrReviewComment.create!(
        job: job,
        pr_type: "direct",
        comment_kind: "issue",
        github_comment_id: SecureRandom.random_number(1_000_000),
        github_handle: "reviewer",
        attributed_to: "external",
        actionable: true,
        body: "Please add tests",
        comment_created_at: 1.hour.ago
      )
      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/ignore", as: :json
    end
  end

  it "lets repository collaborators read dependency options but only write members mutate metadata" do
    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      get "/api/v1/app/jobs/#{job.id}/dependency_options", as: :json
    end

    expect_statuses(owner: :ok, writer: :ok, reader: :forbidden, stranger: :not_found) do
      post "/api/v1/app/jobs/#{job.id}/tags", params: { tag_name: "theme:shared" }, as: :json
    end
  end

  it "lets repository collaborators pin visible jobs without requiring write access" do
    expect_statuses(owner: :ok, writer: :ok, reader: :ok, stranger: :not_found) do
      post "/api/v1/app/jobs/#{job.id}/pin", as: :json
    end
  end

  it "allows only write members to dismiss workflow warnings" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    warning = WorkflowWarnings.record!(
      workflow: workflow,
      kind: "grader_side_effect",
      title: "Grader left changes",
      suggested_prompt: "Fix the grader"
    )

    expect_statuses(owner: :ok, writer: :ok, reader: :forbidden, stranger: :not_found) do
      warning.update_columns(state: "pending")
      post "/api/v1/app/jobs/#{job.id}/workflow_warnings/#{warning.id}/dismiss", as: :json
    end
  end

  it "allows only write members to open Coding Mode for a visible job" do
    allow(Feature).to receive(:coding_mode_enabled?).and_return(true)
    allow(JobCodingMode::Takeover).to receive(:call) do |user:, **|
      chat = instance_double(ChatSession, id: user.id)
      JobCodingMode::Takeover::Result.new(job: job, chat_session: chat, created_chat: true, queued_message: nil)
    end

    expect_statuses(owner: :ok, writer: :ok, reader: :forbidden, stranger: :not_found) do
      post "/api/v1/app/jobs/#{job.id}/open_in_coding_mode", as: :json
    end
  end
end
