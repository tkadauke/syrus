require "rails_helper"

RSpec.describe "API: GET /api/v1/app/repositories/:repository_id/coverage_trend", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  def create_snapshot(branch: "main", lines_pct: 80.0, branches_pct: 60.0, functions_pct: 90.0, created_at: Time.current, project_id: nil)
    job = Factories.job(repository: repository)
    workflow = job.workflows.first
    snap = SyrusCoverage::Snapshot.create!(
      repository: repository,
      workflow: workflow,
      sha: SecureRandom.hex(10),
      branch: branch,
      project_id: project_id,
      lines_pct: lines_pct,
      branches_pct: branches_pct,
      functions_pct: functions_pct
    )
    snap.update_columns(created_at: created_at)
    snap
  end

  it "returns 200 with correct shape when snapshots exist" do
    sign_in_as(user)
    snap = create_snapshot(created_at: 1.day.ago)

    get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["days"]).to eq(30)
    expect(body["trend"]).to be_an(Array)
    expect(body["trend"].first).to include("date", "lines_pct", "branches_pct")
    expect(body["latest"]).to include(
      "lines_pct" => snap.lines_pct.to_f,
      "branches_pct" => snap.branches_pct.to_f,
      "functions_pct" => snap.functions_pct.to_f
    )
  end

  it "excludes project-specific snapshots from repository-level trend and latest values" do
    sign_in_as(user)
    root = create_snapshot(project_id: "repo", lines_pct: 82.0, branches_pct: 62.0, functions_pct: 92.0, created_at: 2.hours.ago)
    create_snapshot(project_id: "desktop", lines_pct: 20.0, branches_pct: 10.0, functions_pct: 30.0, created_at: 1.hour.ago)

    get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["latest"]).to include(
      "lines_pct" => root.lines_pct.to_f,
      "branches_pct" => root.branches_pct.to_f,
      "functions_pct" => root.functions_pct.to_f
    )
    expect(body["trend"].sole).to include("lines_pct" => 82.0)
  end

  it "returns empty trend array when no snapshots exist" do
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["days"]).to eq(30)
    expect(body["trend"]).to eq([])
    expect(body["latest"]).to be_nil
  end

  it "respects the days param" do
    sign_in_as(user)
    old_snap = create_snapshot(created_at: 40.days.ago)
    new_snap = create_snapshot(created_at: 5.days.ago)

    get "/api/v1/app/repositories/#{repository.id}/coverage_trend", params: { days: 10 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["days"]).to eq(10)
    trend_dates = body["trend"].map { |row| row["date"] }
    expect(trend_dates).not_to include(old_snap.created_at.to_date.to_s)
  end

  it "caps the days param and returns an ETag" do
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/coverage_trend", params: { days: 10_000 }

    expect(response).to have_http_status(:ok)
    expect(parse_body["days"]).to eq(365)
    expect(response.headers["ETag"]).to be_present
  end

  it "returns 401 when not signed in" do
    get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 404 for another user's repository" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    get "/api/v1/app/repositories/#{foreign.id}/coverage_trend"

    expect(response).to have_http_status(:not_found)
  end
end
