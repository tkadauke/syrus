require "rails_helper"

RSpec.describe "Landing lanes API", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user:, landing_concurrency: 2) }

  before { sign_in_as(user) }

  it "returns every visible repository with all configured slots" do
    get "/api/v1/app/landing_lanes"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to include("estimate_kind" => "best_case")
    expect(body.fetch("repositories")).to include(
      include("id" => repository.id, "landing_concurrency" => 2, "busy_lane_count" => 0,
        "lanes" => [ include("number" => 1, "empty" => true), include("number" => 2, "empty" => true) ])
    )
  end

  it "does not expose a lane occupied by a policy-hidden Job" do
    Factories.job_record(user:, repository:, issue_number: 41)
    hidden = Factories.job_record(
      user:, repository:, issue_number: 42, state: "landing",
      origin: "private_tasks", origin_id: "hidden"
    )
    workflow = Workflow.create!(job: hidden, trigger_kind: "auto_merge", state: "running")
    intent = WorkIntent.create!(
      kind: "auto_merge", state: "requested", repository:, scope_type: "job", scope_id: hidden.id,
      actor: user, source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent, workflow:, kind: "auto_merge", state: "running", repository:,
      scope_type: "job", scope_id: hidden.id
    )
    unit.work_unit_members.create!(job: hidden, role: "primary")
    unit.work_unit_locks.create!(lock_key: "landing:repository:#{repository.id}")

    with_job_visibility_restriction(origin: "private_tasks", visible_origin_ids: []) do
      expect(Job.visible_to(user)).not_to include(hidden)
      get "/api/v1/app/landing_lanes"

      repo = JSON.parse(response.body).fetch("repositories").find { |entry| entry.fetch("id") == repository.id }
      expect(repo).to include("busy_lane_count" => 0)
      expect(repo.fetch("lanes").first).to include("empty" => true)
      expect(response.body).not_to include(hidden.slug, workflow.slug)
    end
  end
end
