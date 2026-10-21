require "rails_helper"

RSpec.describe "App API slug refs", type: :request do
  let!(:bootstrap_admin) { Factories.user(global_role: "admin") }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def parse_body = JSON.parse(response.body)

  before { sign_in_as(user) }

  it "resolves accessible Job refs" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Patch aqueduct")

    get "/api/v1/app/slug_refs/JOB-#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "JOB-#{job.id}",
      "type" => "job",
      "prefix" => "JOB",
      "display_label" => "Job",
      "numeric_id" => job.id,
      "accessible" => true,
      "web_path" => "/jobs/JOB-#{job.id}",
      "api_preview_path" => "/api/v1/app/jobs/JOB-#{job.id}",
      "copyable" => true,
      "preview_available" => true,
      "linkifies_generated_text" => true,
      "mobile_interaction_hints" => { "tap" => "open", "long_press" => "copy" }
    )
  end

  it "resolves accessible Epic refs by display number" do
    epic = Factories.epic(user: user, repository: repository, title: "Lift arches", number: 51)
    expect(epic.id).not_to eq(epic.number)

    get "/api/v1/app/slug_refs/epic-#{epic.number}"

    expect(response).to have_http_status(:ok)
    slug_ref = parse_body.fetch("slug_ref")
    expect(slug_ref).to include(
      "canonical_slug" => "EPIC-#{epic.number}",
      "type" => "epic",
      "numeric_id" => epic.number,
      "accessible" => true,
      "web_path" => "/epics/EPIC-#{epic.number}",
      "api_preview_path" => "/api/v1/app/epics/EPIC-#{epic.number}"
    )

    get slug_ref.fetch("api_preview_path")
    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "id")).to eq(epic.id)
  end

  it "resolves accessible Chat refs" do
    chat = ChatSession.create!(user: user, title: "Launch planning")

    get "/api/v1/app/slugs/CHAT-#{chat.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "CHAT-#{chat.id}",
      "type" => "chat",
      "numeric_id" => chat.id,
      "accessible" => true,
      "web_path" => "/chats/#{chat.id}",
      "api_preview_path" => "/api/v1/app/chats/#{chat.id}/preview"
    )
  end

  it "resolves accessible Workflow refs and serves a projected preview" do
    job = Factories.job_record(user: user, repository: repository)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
    workflow.steps.create!(kind: "prepare", position: 1, state: "succeeded")
    workflow.steps.create!(kind: "grader", position: 2, state: "failed", details: { "accepted_failure" => true, "name" => "focused" })

    get "/api/v1/app/slug_refs/WF-#{workflow.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "WF-#{workflow.id}",
      "type" => "workflow",
      "web_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}",
      "api_preview_path" => "/api/v1/app/workflows/#{workflow.id}/preview"
    )

    get "/api/v1/app/workflows/#{workflow.id}/preview"
    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("workflow")).to include(
      "slug" => "WF-#{workflow.id}",
      "trigger_label" => "Initial implementation",
      "state" => "failed"
    )
    expect(parse_body.dig("workflow", "steps").last).to include("display_name" => "Focused", "status" => "warning")
  end

  it "resolves accessible Run refs to their owning workflows" do
    job = Factories.job_with_run(user: user)
    run = job.runs.first

    get "/api/v1/app/slug_refs/RUN-#{run.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "RUN-#{run.id}",
      "type" => "run",
      "web_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{run.workflow.id}",
      "api_preview_path" => nil,
      "linkifies_generated_text" => true
    )
  end

  it "does not expose inaccessible Workflow refs or previews" do
    other_user = Factories.user(global_role: "user")
    other_repository = Factories.repository(user: other_user)
    job = Factories.job_record(user: other_user, repository: other_repository)
    workflow = Workflow.create!(job: job, trigger_kind: "initial")

    get "/api/v1/app/slug_refs/WF-#{workflow.id}"
    expect(parse_body.fetch("slug_ref")).to include("accessible" => false, "web_path" => nil)

    get "/api/v1/app/workflows/#{workflow.id}/preview"
    expect(response).to have_http_status(:not_found)
  end

  it "does not resolve a Workflow outside an invocation token's scope" do
    admin = Factories.user(admin: true)
    invocation_job = Factories.job_with_run(user: admin, issue_number: 100, run_attrs: { state: "running" })
    other_workflow = Factories.job(user: admin, repository: invocation_job.repository, issue_number: 101).workflows.first
    token = McpInvocationContext.issue_for_app_run(invocation_job.runs.first, expires_in: 5.minutes)

    get "/api/v1/app/slug_refs/WF-#{other_workflow.id}",
        headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "WF-#{other_workflow.id}",
      "accessible" => false,
      "web_path" => nil,
      "api_preview_path" => nil
    )
  end

  it "resolves plugin-owned Design Doc refs through the slug type registry" do
    design_doc = DesignDocs::DesignDoc.create!(
      owner_user: user,
      title: "Bridge plan",
      markdown: "# Bridge",
      visibility: "private"
    )
    version = design_doc.versions.create!(
      markdown: design_doc.markdown,
      version_number: 1,
      actor_kind: "user",
      actor_user: user
    )
    design_doc.update!(current_version: version)

    get "/api/v1/app/slug_refs/DOC-#{design_doc.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "DOC-#{design_doc.id}",
      "type" => "doc",
      "prefix" => "DOC",
      "display_label" => "Design Doc",
      "numeric_id" => design_doc.id,
      "accessible" => true,
      "web_path" => "/design_docs/#{design_doc.id}",
      "api_preview_path" => "/api/v1/app/design_docs/#{design_doc.id}/preview",
      "copyable" => true,
      "preview_available" => true
    )
  end

  it "returns a neutral inaccessible payload for known private records" do
    other_user = Factories.user(global_role: "user")
    private_repo = Factories.repository(user: other_user, owner: "private", name: "repo")
    private_job = Factories.job_record(user: other_user, repository: private_repo, issue_title: "Private")

    get "/api/v1/app/slug_refs/JOB-#{private_job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "JOB-#{private_job.id}",
      "type" => "job",
      "numeric_id" => private_job.id,
      "accessible" => false,
      "copyable" => true,
      "preview_available" => true
    )
    expect(parse_body.fetch("slug_ref")).to include("web_path" => nil, "api_preview_path" => nil)
    expect(parse_body.to_s).not_to include("Private")
  end

  it "returns the same neutral payload for missing known refs" do
    get "/api/v1/app/slug_refs/JOB-999999"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("slug_ref")).to include(
      "canonical_slug" => "JOB-999999",
      "type" => "job",
      "numeric_id" => 999999,
      "accessible" => false,
      "web_path" => nil,
      "api_preview_path" => nil
    )
  end

  it "rejects unknown prefixes" do
    get "/api/v1/app/slug_refs/NOTE-1"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
  end

  it "rejects malformed known refs" do
    get "/api/v1/app/slug_refs/JOB-nope"

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("bad_request")
  end
end
