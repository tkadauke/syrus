require "rails_helper"

RSpec.describe "per-origin Job visibility", type: :request do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "private-jobs") }
  let!(:ordinary_job) { Factories.job_record(repository: repository, issue_number: 40, issue_title: "Ordinary work") }
  let!(:restricted_job) do
    Factories.job_record(
      repository: repository,
      issue_number: 41,
      issue_title: "Private task",
      origin: "private_tasks",
      origin_id: "7"
    )
  end

  before { sign_in_as(user) }

  around do |example|
    with_job_visibility_restriction(origin: "private_tasks", visible_origin_ids: []) { example.run }
  end

  it "omits restricted Jobs from the Jobs API and its count" do
    get "/api/v1/app/jobs", params: { include_active_work: true }

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.fetch("count")).to eq(1)
    expect(payload.fetch("jobs").map { |job| job.fetch("id") }).to eq([ ordinary_job.id ])
  end

  it "does not expose restricted Job detail" do
    get "/api/v1/app/jobs/#{restricted_job.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "omits restricted Jobs from dashboard rows and counts" do
    get "/api/v1/app/dashboard", params: { subject: "job", view: "list", scope: "mine", smart_folder_id: "" }

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.fetch("total")).to eq(1)
    expect(payload.dig("counts", "jobs")).to eq(1)
    expect(payload.fetch("items").map { |job| job.fetch("id") }).to eq([ ordinary_job.id ])
  end

  it "omits restricted Jobs and counts from repository detail" do
    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)
    expect(payload.dig("pagination", "total_jobs")).to eq(1)
    expect(payload.fetch("jobs").map { |job| job.fetch("id") }).to eq([ ordinary_job.id ])
  end
end
