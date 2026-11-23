require "rails_helper"

RSpec.describe "API: review workspace", type: :request do
  let!(:instance_admin) { Factories.user }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true) }

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

  it "uses the same eligible stack for the list and badge" do
    job = Factories.job_record(user:, repository:, state: "implemented", issue_title: "Review me", finished_at: 1.hour.ago)

    get "/api/v1/app/review_workspace"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 1)
    expect(response.parsed_body.fetch("jobs")).to contain_exactly(
      include("id" => job.id, "revision" => job.entity_revision, "slug" => job.slug, "title" => "Review me")
    )

    get "/api/v1/app/review_workspace/count"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 1)
  end

  it "rejects a review decision rendered from an older Job revision" do
    job = Factories.job_record(user:, repository:, state: "implemented", issue_title: "Review me")
    rendered_revision = job.entity_revision
    job.update!(pr_checks_state: "failing")

    expect {
      post "/api/v1/app/jobs/#{job.id}/approve", params: { expected_revision: rendered_revision }
    }.not_to change(JobApproval, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("stale_job")
  end

  it "fails closed after the plugin is disabled" do
    PluginRecord.find_by!(name: "review_workspace").update!(enabled: false)

    get "/api/v1/app/review_workspace"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("error").fetch("code")).to eq("plugin_disabled")
  end

  it "limits run invocation tokens to their current Job", :skip_sign_in do
    admin = Factories.user(admin: true)
    scoped_repository = Factories.repository(user: admin, auto_merge_enabled: true)
    current_job = Factories.job_with_run(
      user: admin,
      repository: scoped_repository,
      state: "implemented",
      issue_title: "Current invocation",
      run_attrs: { state: "running" }
    )
    outside_job = Factories.job_record(
      user: admin,
      repository: scoped_repository,
      state: "implemented",
      issue_title: "Outside invocation"
    )
    token = McpInvocationContext.issue_for_app_run(current_job.runs.first, expires_in: 5.minutes)

    get "/api/v1/app/review_workspace", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 0, "jobs" => [])
    expect(response.body).not_to include(outside_job.issue_title)

    get "/api/v1/app/review_workspace/count", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 0)

    get "/api/v1/app/dashboard", params: { subject: "job", section: "chrome" },
      headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("ui_panels").pluck("id")).not_to include("review_workspace.ready_jobs")
  end

  describe "GET /api/v1/app/review_workspace/:id/summary" do
    it "aggregates change scope from the stored diff review version" do
      job = Factories.job_record(user:, repository:, state: "implemented", issue_title: "Scope me")
      DiffReviewVersion.create!(
        job:, version_index: 1, base_sha: "a" * 40, head_sha: "b" * 40, source_key: "k", reason: "source_diff",
        files_snapshot: [ { "path" => "a.rb", "additions" => 3, "deletions" => 1 }, { "path" => "b.rb", "additions" => 2, "deletions" => 0 } ]
      )

      get "/api/v1/app/review_workspace/#{job.id}/summary"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("change_scope")).to eq("files_changed" => 2, "additions" => 5, "deletions" => 1, "truncated" => false)
    end

    it "reports the head of the newest succeeded implementation step" do
      job = Factories.job_with_run(
        user:, repository:, state: "implemented", issue_title: "Head",
        step_attrs: { state: "succeeded" }, run_attrs: { state: "succeeded", head_sha: "c" * 40 }
      )

      get "/api/v1/app/review_workspace/#{job.id}/summary"

      expect(response.parsed_body).to include("current_head_sha" => "c" * 40)
    end

    it "returns a null change scope when no diff was stored" do
      job = Factories.job_record(user:, repository:, state: "implemented", issue_title: "No diff")

      get "/api/v1/app/review_workspace/#{job.id}/summary"

      expect(response.parsed_body).to include("change_scope" => nil, "current_head_sha" => nil)
    end
  end
end
