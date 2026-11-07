require "rails_helper"

RSpec.describe "API: /api/v1/admin/runs", type: :request do
  let!(:admin)        { Factories.user }
  let!(:admin_token)  { admin.generate_api_token! }
  let(:non_admin)     { Factories.user }
  let(:non_admin_tok) { non_admin.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)
  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql.squish unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  let(:job) { Factories.job(user: admin) }

  describe "auth" do
    it "401s without a token" do
      get "/api/v1/admin/runs"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for a non-admin token" do
      get "/api/v1/admin/runs", headers: auth(non_admin_tok)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/admin/runs" do
    let!(:run_a) do
      r = job.initial_run
      r.update!(state: "succeeded", started_at: 2.hours.ago, finished_at: 90.minutes.ago)
      r
    end
    let!(:run_b) do
      step = job.workflows.last.steps.find_by(kind: "implement")
      Run.create!(job: job, step: step, trigger_kind: "ci_failure",
                  state: "failed", started_at: 1.hour.ago, finished_at: 30.minutes.ago).tap do |run|
        run.create_run_failure_classification!(
          classification: "worker_died",
          confidence: 0.95,
          retryable: true,
          reason: "The worker process disappeared while the run was active.",
          diagnostic_summary: "agent_outcome=worker_died",
          classifier_inputs: { "agent_outcome" => "worker_died" },
          classified_at: 20.minutes.ago
        )
      end
    end

    it "returns the compact shape with workflow/step context" do
      run_b.update!(agent_outcome: "worker_died")

      get "/api/v1/admin/runs", headers: auth
      expect(response).to be_successful

      row = parse_body["runs"].find { |r| r["id"] == run_b.id }
      expect(row).to include(
        "id"           => run_b.id,
        "state"        => "failed",
        "trigger_kind" => "ci_failure",
        "job_id"       => job.id,
        "step_kind"    => "implement",
        "failure_category" => "agent_process_died"
      )
      expect(row["failure_classification"]).to include(
        "classification" => "worker_died",
        "retryable" => true
      )
      expect(row["failure_classification"]).not_to have_key("classifier_inputs")
    end

    it "filters by state" do
      get "/api/v1/admin/runs", params: { state: "failed" }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)
      expect(ids).not_to include(run_a.id)
    end

    it "filters by trigger_kind" do
      get "/api/v1/admin/runs", params: { trigger_kind: "ci_failure" }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)
      expect(ids).not_to include(run_a.id)
    end

    it "filters by job_id" do
      other_job = Factories.job(user: admin, issue_number: 99,
                                 repository: Factories.repository(user: admin, owner: "globex", name: "things"))
      foreign_run = other_job.initial_run

      get "/api/v1/admin/runs", params: { job_id: job.id }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_a.id)
      expect(ids).not_to include(foreign_run.id)
    end

    it "filters by run_id without scanning the global run list" do
      get "/api/v1/admin/runs", params: { run_id: run_b.id }, headers: auth

      expect(parse_body["total"]).to eq(1)
      expect(parse_body["runs"].map { |r| r["id"] }).to eq([ run_b.id ])
    end

    it "filters by ?since (gte against finished_at COALESCE started_at)" do
      get "/api/v1/admin/runs", params: { since: 45.minutes.ago.iso8601 }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)        # finished 30m ago — passes
      expect(ids).not_to include(run_a.id)        # finished 90m ago — too old
    end

    it "ignores garbage in ?since (degrades to wide window, not 400)" do
      get "/api/v1/admin/runs", params: { since: "not-a-timestamp" }, headers: auth
      expect(response).to be_successful
    end

    it "respects ?per up to MAX_PER and returns total count" do
      # Cap test — confirm the per param is honored.
      get "/api/v1/admin/runs", params: { per: 1 }, headers: auth
      expect(parse_body["per"]).to eq(1)
      expect(parse_body["runs"].size).to eq(1)
      expect(parse_body["total"]).to be >= 2
    end

    it "clamps ?per to MAX_PER (100)" do
      get "/api/v1/admin/runs", params: { per: 9999 }, headers: auth
      expect(parse_body["per"]).to eq(100)
    end

    it "paginates via ?page" do
      get "/api/v1/admin/runs", params: { per: 1, page: 2 }, headers: auth
      expect(parse_body["page"]).to eq(2)
      expect(parse_body["runs"].size).to be <= 1
    end
  end

  describe "GET /api/v1/admin/runs/:run_id/artifacts" do
    it "returns ordered JobLog rows and run context for a specific run" do
      diff = "diff --git a/app.rb b/app.rb"
      step = job.workflows.last.steps.find_by(kind: "implement")
      run = Run.create!(job: job, step: step, trigger_kind: "auto_merge",
                        state: "cancelled", agent_diff: diff)
      JobLog.append!(run: run, chunk: "starting auto_merge run", kind: nil)
      JobLog.append!(run: run, chunk: "auto_merge: deferred - mergeable_state=unknown", kind: "system")

      get "/api/v1/admin/runs/#{run.id}/artifacts", params: { include: "diff,logs" }, headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body).to include(
        "job_id" => job.id,
        "workflow_id" => run.step.workflow_id,
        "step_id" => run.step_id,
        "step_kind" => run.step.kind,
        "run_id" => run.id,
        "state" => "cancelled",
        "trigger_kind" => "auto_merge",
        "agent_diff" => diff,
        "agent_diff_bytes" => diff.bytesize,
        "logs_count" => 2
      )
      expect(body["logs"].map { |log| log.slice("sequence", "kind", "chunk") }).to eq([
        { "sequence" => 0, "kind" => nil, "chunk" => "starting auto_merge run" },
        { "sequence" => 1, "kind" => "system", "chunk" => "auto_merge: deferred - mergeable_state=unknown" }
      ])
      expect(body["logs"].first["created_at"]).to be_present
    end

    it "omits heavyweight diff and logs unless requested" do
      run = job.initial_run
      run.update!(agent_diff: "large diff")
      JobLog.append!(run: run, chunk: "large log", kind: "system")

      get "/api/v1/admin/runs/#{run.id}/artifacts", headers: auth

      expect(parse_body).to include("agent_diff" => nil, "agent_diff_bytes" => nil, "logs" => [], "logs_count" => 0)
    end

    it "does not eager-load full JobLog rows" do
      run = job.initial_run
      JobLog.append!(run: run, chunk: "diagnostic row", kind: "system")

      sql = capture_sql do
        get "/api/v1/admin/runs/#{run.id}/artifacts", params: { include: "logs" }, headers: auth
      end

      job_log_selects = sql.select { |statement| statement.match?(/FROM [`"]?job_logs[`"]?/i) }
      expect(job_log_selects).not_to include(match(/SELECT [`"]?job_logs[`"]?\.\*/i))
      expect(job_log_selects.join("\n")).to include("chunk")
    end

    it "403s for a non-admin token" do
      get "/api/v1/admin/runs/#{job.initial_run.id}/artifacts", headers: auth(non_admin_tok)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "host admission attribution" do
    let(:deferral) do
      { "action" => "defer", "reason" => "host_resource_semaphore_busy", "hostname" => "worker-a",
        "resource_guard_binding_terms" => [ "compute_units" ], "deferral_count" => 3 }
    end

    def record_deferral(run, workflow)
      workflow.update!(artifacts: (workflow.artifacts || {}).merge("run_host_admission" => deferral.merge("run_id" => run.id)))
    end

    it "reports the deferral on a queued Run in the list and artifacts endpoints" do
      run = job.initial_run
      run.update!(state: "queued")
      record_deferral(run, run.step.workflow)

      get "/api/v1/admin/runs", params: { run_id: run.id }, headers: auth
      expect(parse_body["runs"].first["host_admission"]).to include(
        "reason" => "host_resource_semaphore_busy", "resource_guard_binding_terms" => [ "compute_units" ]
      )

      get "/api/v1/admin/runs/#{run.id}/artifacts", headers: auth
      expect(parse_body["host_admission"]).to include("reason" => "host_resource_semaphore_busy", "deferral_count" => 3)
    end

    it "does not retain stale attribution once the Run is terminal" do
      run = job.initial_run
      run.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
      record_deferral(run, run.step.workflow)

      get "/api/v1/admin/runs", params: { run_id: run.id }, headers: auth
      expect(parse_body["runs"].first["host_admission"]).to be_nil

      get "/api/v1/admin/runs/#{run.id}/artifacts", headers: auth
      expect(parse_body["host_admission"]).to be_nil
    end

    it "does not attribute another Run's deferral to a queued Run" do
      run = job.initial_run
      run.update!(state: "queued")
      record_deferral(run, run.step.workflow)
      run.step.workflow.update!(artifacts: { "run_host_admission" => deferral.merge("run_id" => run.id + 1000) })

      get "/api/v1/admin/runs", params: { run_id: run.id }, headers: auth

      expect(parse_body["runs"].first["host_admission"]).to be_nil
    end
  end
end
