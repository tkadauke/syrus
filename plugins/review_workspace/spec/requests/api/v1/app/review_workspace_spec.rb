require "rails_helper"

RSpec.describe "API: review workspace", type: :request do
  let!(:instance_admin) { Factories.user }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true) }

  before { sign_in_as(user) }

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
end
