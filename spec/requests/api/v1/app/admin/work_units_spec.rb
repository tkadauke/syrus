require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/work_units", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:other_repo) { Factories.repository(user: other_user, owner: "acme", name: "elsewhere") }

  def parse_body
    JSON.parse(response.body)
  end

  it "requires an admin user" do
    user.update!(global_role: "user")
    sign_in_as(user)

    get "/api/v1/app/admin/work_units"

    expect(response).to have_http_status(:forbidden)
  end

  it "lists intents and units across users with job and workflow links" do
    sign_in_as(admin)
    first = work_unit_fixture(user: user, repository: repo, issue_number: 10, kind: "initial")
    second = work_unit_fixture(user: other_user, repository: other_repo, issue_number: 11, kind: "ci_failure")
    AppSetting.current.update!(show_work_unit_debug: true)

    get "/api/v1/app/admin/work_units"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("settings", "show_work_unit_debug")).to be true
    expect(body.dig("filter_schema").map { |field| field["field"] }).to include("intent_state", "intent_kind", "unit_state", "unit_kind", "job_id", "workflow_id")
    expect(body.dig("intents").map { |intent| intent["id"] }).to include(first.fetch(:intent).id, second.fetch(:intent).id)

    serialized = body.fetch("intents").find { |intent| intent["id"] == first.fetch(:intent).id }
    expect(serialized).to include(
      "kind" => "initial",
      "label" => "Initial implementation",
      "state" => "requested",
      "repository" => include("slug" => "acme/widgets"),
      "actor" => include("id" => user.id)
    )
    expect(serialized.fetch("jobs")).to include(include("id" => first.fetch(:job).id, "path" => "/jobs/#{first.fetch(:job).id}"))
    expect(serialized.fetch("units")).to include(
      include(
        "id" => first.fetch(:unit).id,
        "workflow" => include(
          "id" => first.fetch(:workflow).id,
          "path" => "/jobs/#{first.fetch(:job).id}?tab=workflows#workflow-#{first.fetch(:workflow).id}"
        )
      )
    )
  end

  it "filters by job membership" do
    sign_in_as(admin)
    matching = work_unit_fixture(user: user, repository: repo, issue_number: 12, kind: "initial")
    work_unit_fixture(user: other_user, repository: other_repo, issue_number: 13, kind: "ci_failure")
    q = Filters::QueryParam.encode("and" => [ { "field" => "job_id", "op" => "is", "value" => matching.fetch(:job).id } ])

    get "/api/v1/app/admin/work_units", params: { q: q }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("intents").map { |intent| intent["id"] }).to eq([ matching.fetch(:intent).id ])
  end

  def work_unit_fixture(user:, repository:, issue_number:, kind:)
    job = Factories.job_record(user: user, repository: repository, issue_number: issue_number, issue_title: "Do #{kind}")
    workflow = Workflow.create!(job: job, trigger_kind: kind, state: "running", agent_provider: "claude")
    intent = WorkIntent.create!(kind: kind, state: "requested", repository: repository, scope_type: "job", scope_id: job.id, actor: user)
    unit = WorkUnit.create!(work_intent: intent, workflow: workflow, kind: kind, state: "running", repository: repository, scope_type: "job", scope_id: job.id, started_at: Time.current)
    WorkUnitMember.create!(work_unit: unit, job: job, role: "primary")
    { job: job, workflow: workflow, intent: intent, unit: unit }
  end
end
