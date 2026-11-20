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
    expect(response.parsed_body.fetch("jobs")).to contain_exactly(include("id" => job.id, "slug" => job.slug, "title" => "Review me"))

    get "/api/v1/app/review_workspace/count"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 1)
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
  end
end
