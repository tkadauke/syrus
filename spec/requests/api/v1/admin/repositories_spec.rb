require "rails_helper"

RSpec.describe "API: /api/v1/admin/repositories", type: :request do
  let(:admin) { Factories.user }
  let(:token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{token}" }
  def body = JSON.parse(response.body)

  it "lists repositories with active job count and last job" do
    repo = Factories.repository(user: admin, owner: "acme", name: "widgets")
    older = Factories.job_record(user: admin, repository: repo, issue_title: "Older", state: "closed", updated_at: 2.days.ago)
    newer = Factories.job_record(user: admin, repository: repo, issue_title: "Newer", state: "queued", updated_at: 1.hour.ago)
    older.update!(updated_at: 2.days.ago)
    newer.update!(updated_at: 1.hour.ago)

    get "/api/v1/admin/repositories", headers: auth

    expect(response).to have_http_status(:ok)
    row = body.fetch("repositories").find { |repository| repository["slug"] == "acme/widgets" }
    expect(row).to include("active_jobs" => 1)
    expect(row.fetch("last_job")).to include("id" => newer.id, "title" => "Newer")
  end
end
