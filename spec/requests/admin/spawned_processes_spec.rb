require "rails_helper"

RSpec.describe "Admin spawned processes (HTML)", type: :request do
  let(:user) { Factories.user(admin: true) }

  before { sign_in_as(user) }

  def fixture(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-test",
      started_at: 30.seconds.ago,
      last_chunk_at: 5.seconds.ago,
      run: nil,
      workflow: nil
    }.merge(overrides))
  end

  describe "GET /admin/processes" do
    it "lists active and recently-finished rows" do
      running = fixture
      recent = fixture(started_at: 5.minutes.ago, finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)
      ancient = fixture(started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)

      get admin_processes_path

      expect(response.body).to include("Process ##{running.id}").or include(running.command)
      expect(response.body).to include(recent.command)
      expect(response.body).not_to include("Process ##{ancient.id}")
    end

    it "filters by ?state=running" do
      running = fixture
      fixture(started_at: 10.minutes.ago, finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)

      get admin_processes_path, params: { state: "running" }
      doc = Nokogiri::HTML(response.body)
      shown_rows = doc.css("tbody tr").size
      expect(shown_rows).to eq(1)
    end

    it "filters by an encoded state chip" do
      running = fixture
      finished = fixture(command: "finished command", started_at: 10.minutes.ago, finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)
      q = Filters::QueryParam.encode("field" => "state", "op" => "is", "value" => "running")

      get admin_processes_path, params: { q: q }

      expect(response.body).to include(running.command)
      expect(response.body).not_to include(finished.command)
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("tbody tr").size).to eq(1)
    end

    it "filters by ?kind=" do
      fixture(kind: "agent")
      grader = fixture(kind: "grader", command: "bin/rspec")

      get admin_processes_path, params: { kind: "grader" }
      expect(response.body).to include(grader.command)
      expect(response.body).not_to include("claude --print")
    end

    it "renders a Kill button on running rows without a kill request" do
      sp = fixture
      get admin_processes_path
      expect(response.body).to include(kill_admin_process_path(sp))
    end

    it "hides the Kill button once kill_requested_at is set" do
      sp = fixture(kill_requested_at: Time.current)
      get admin_processes_path
      expect(response.body).to include("kill requested")
      # The form action should not be rendered as a button for this row
      doc = Nokogiri::HTML(response.body)
      row_actions = doc.at_xpath("//td[contains(., 'Detail')]")
      expect(row_actions&.css("form[action='#{kill_admin_process_path(sp)}']")).to be_empty
    end
  end

  describe "GET /admin/processes/:id" do
    it "renders the detail dl" do
      sp = fixture
      get admin_process_path(sp)
      expect(response.body).to include("Process ##{sp.id}")
      expect(response.body).to include("syrus-worker-test")
    end
  end

  describe "POST /admin/processes/:id/kill" do
    it "stamps kill_requested_at and redirects with a notice" do
      sp = fixture
      expect { post kill_admin_process_path(sp) }.to change { sp.reload.kill_requested_at }.from(nil)
      expect(response).to redirect_to(admin_processes_path)
      expect(flash[:notice]).to include("Kill requested for process ##{sp.id}")
      expect(sp.kill_requested_by_user).to eq(user)
    end

    it "refuses to kill an already-finalized process" do
      sp = fixture(finished_at: Time.current, outcome: "succeeded", exit_status: 0)
      expect { post kill_admin_process_path(sp) }.not_to change { sp.reload.kill_requested_at }
      expect(flash[:alert]).to include("already finalized")
    end
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
