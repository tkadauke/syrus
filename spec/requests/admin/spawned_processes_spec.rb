require "rails_helper"

RSpec.describe "Admin spawned processes (HTML shell)", type: :request do
  let(:user) { Factories.user(admin: true) }

  before { sign_in_as(user) }

  describe "GET /admin/processes" do
    it "serves the React processes shell" do
      get admin_processes_path
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /admin/processes/:id" do
    it "serves the React process detail shell" do
      sp = SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        hostname: "syrus-worker-test",
        started_at: 30.seconds.ago,
        last_chunk_at: 5.seconds.ago
      )
      get admin_process_path(sp)
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route the retired legacy HTML process endpoints" do
    expect {
      Rails.application.routes.recognize_path("/admin/processes/legacy", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/processes/legacy/1", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/processes/1/kill", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end

RSpec.describe "Admin spawned processes (API)", type: :request do
  let(:user) { Factories.user(admin: true) }

  before do
    user.generate_api_token!
    @token = user.api_token
  end

  def fixture(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-test",
      started_at: 30.seconds.ago,
      last_chunk_at: 5.seconds.ago
    }.merge(overrides))
  end

  def headers
    { "Authorization" => "Bearer #{@token}" }
  end

  describe "GET /api/v1/admin/processes" do
    it "returns active + recent by default" do
      running = fixture
      fixture(started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)

      get "/api/v1/admin/processes", headers: headers
      payload = JSON.parse(response.body)
      expect(payload["processes"].map { |p| p["id"] }).to include(running.id)
      expect(payload["running_total"]).to eq(SpawnedProcess.running.count)
    end

    it "filters by ?state=running" do
      running = fixture
      fixture(started_at: 1.minute.ago, finished_at: 30.seconds.ago, outcome: "succeeded", exit_status: 0)

      get "/api/v1/admin/processes", params: { state: "running" }, headers: headers
      payload = JSON.parse(response.body)
      expect(payload["processes"].map { |p| p["id"] }).to eq([ running.id ])
    end

    it "filters by ?kind=" do
      fixture(kind: "agent")
      grader = fixture(kind: "grader", command: "bin/rspec")

      get "/api/v1/admin/processes", params: { kind: "grader" }, headers: headers
      payload = JSON.parse(response.body)
      expect(payload["processes"].map { |p| p["id"] }).to eq([ grader.id ])
    end

    it "includes key on spawned_process smart folders" do
      fixture(started_at: 10.minutes.ago, last_chunk_at: 10.minutes.ago)

      get "/api/v1/admin/processes", headers: headers
      payload = JSON.parse(response.body)

      running_folder = payload["smart_folders"].find { |f| f["name"] == "Running" }
      expect(running_folder).to be_present
      expect(running_folder["key"]).to eq("running")

      stale_folder = payload["smart_folders"].find { |f| f["name"] == "Stale" }
      expect(stale_folder).to be_present
      expect(stale_folder["key"]).to eq("stale")
    end
  end

  describe "GET /api/v1/admin/processes/:id" do
    it "returns the detail including host_metrics: null on non-linux" do
      sp = fixture
      get "/api/v1/admin/processes/#{sp.id}", headers: headers
      payload = JSON.parse(response.body)
      expect(payload["id"]).to eq(sp.id)
      expect(payload["kind"]).to eq("agent")
      expect(payload).to have_key("host_metrics")
    end
  end

  describe "POST /api/v1/admin/processes/:id/kill" do
    it "stamps kill_requested_at" do
      sp = fixture
      expect {
        post "/api/v1/admin/processes/#{sp.id}/kill", headers: headers
      }.to change { sp.reload.kill_requested_at }.from(nil)
      payload = JSON.parse(response.body)
      expect(payload["kill_requested_at"]).to be_present
    end

    it "returns 409 if already finished" do
      sp = fixture(finished_at: Time.current, outcome: "succeeded", exit_status: 0)
      post "/api/v1/admin/processes/#{sp.id}/kill", headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end
end
