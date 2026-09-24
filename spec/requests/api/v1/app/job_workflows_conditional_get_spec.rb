require "rails_helper"

RSpec.describe "App API job workflows conditional GET", type: :request do
  let(:user) { Factories.user }
  let(:job) { Factories.job_with_run(user: user, repository: Factories.repository(user: user)) }

  before { sign_in_as(user) }

  it "returns a 304 with no body when the workflows tree has not changed since the last ETag" do
    get "/api/v1/app/jobs/#{job.id}/workflows"
    expect(response).to have_http_status(:ok)
    etag = response.headers["ETag"]
    expect(etag).to be_present

    get "/api/v1/app/jobs/#{job.id}/workflows", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_blank
  end

  it "returns a fresh 200 once a nested Step changes, even though the ETag was previously fresh" do
    get "/api/v1/app/jobs/#{job.id}/workflows"
    etag = response.headers["ETag"]

    job.workflows.first.steps.first.update!(state: "running")

    get "/api/v1/app/jobs/#{job.id}/workflows", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to have_key("workflows")
  end
end
