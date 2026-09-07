require "rails_helper"

RSpec.describe "API: /api/v1/admin/worker_timeline", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }

  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "running") }

  def enable_plugin!
    PluginRecord.find_by!(name: "worker_timeline").update!(enabled: true)
  end

  describe "GET /macro" do
    it "answers plugin_disabled while the plugin is disabled" do
      get "/api/v1/admin/worker_timeline/macro", headers: auth

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "requires an API token" do
      enable_plugin!

      get "/api/v1/admin/worker_timeline/macro"

      expect(response).to have_http_status(:unauthorized)
    end

    it "requires an admin user" do
      enable_plugin!
      admin # ensure admin is the first user created, so this one is not auto-promoted
      non_admin = Factories.user
      token = non_admin.generate_api_token!

      get "/api/v1/admin/worker_timeline/macro", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns lanes filtered by repository_id, job_id, hostname, and status" do
      enable_plugin!
      other_repository = Factories.repository(user: admin)
      other_job = Factories.job_record(user: admin, repository: other_repository, state: "running")

      matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago, worker_hostname: "worker-y")

      get "/api/v1/admin/worker_timeline/macro",
          params: { repository_id: repository.id, job_id: job.id, hostname: "worker-x", status: "running" },
          headers: auth

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      span_workflow_ids = body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }
      expect(span_workflow_ids).to eq([ matching.id ])
      expect(body.fetch("lanes").map { |lane| lane.fetch("hostname") }.uniq).to eq([ "worker-x" ])
    end

    it "returns lanes filtered by job_type, accepting infra as a system alias" do
      enable_plugin!
      infrastructure_job = Factories.job_record(user: admin, repository: repository, state: "running", kind: "main_grader", issue_number: nil)

      Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      infrastructure = Workflow.create!(job: infrastructure_job, trigger_kind: "main_grader", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-y")

      get "/api/v1/admin/worker_timeline/macro",
          params: { job_type: "infra" },
          headers: auth

      expect(response).to have_http_status(:ok)
      span_workflow_ids = response.parsed_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }
      expect(span_workflow_ids).to eq([ infrastructure.id ])
    end

    it "reuses WorkUnits::StartBlock for a currently-blocked pending workflow" do
      enable_plugin!
      queued_job = Factories.job_record(user: admin, repository: repository, state: "queued")
      queued_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: queued_job)
      queued_workflow.work_unit.block!(
        reason: "provider_availability",
        blocked_until: 10.minutes.from_now,
        details: { "provider" => "codex" }
      )

      get "/api/v1/admin/worker_timeline/macro", params: { job_id: queued_job.id }, headers: auth

      expect(response).to have_http_status(:ok)
      pending_entry = response.parsed_body.fetch("pending").find { |entry| entry.fetch("workflow_id") == queued_workflow.id }
      expect(pending_entry.dig("blocked", "blocked_reason")).to eq("provider_availability")
      expect(pending_entry.dig("blocked", "available")).to be(true)
      expect(pending_entry.dig("blocked", "historical")).to be(false)
    end
  end

  describe "GET /workflow" do
    it "answers plugin_disabled while the plugin is disabled" do
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

      get "/api/v1/admin/worker_timeline/workflow", params: { id: workflow.id }, headers: auth

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "requires an API token" do
      enable_plugin!
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

      get "/api/v1/admin/worker_timeline/workflow", params: { id: workflow.id }

      expect(response).to have_http_status(:unauthorized)
    end

    it "requires an admin user" do
      enable_plugin!
      admin # ensure admin is the first user created, so this one is not auto-promoted
      non_admin = Factories.user
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

      get "/api/v1/admin/worker_timeline/workflow",
          params: { id: workflow.id },
          headers: { "Authorization" => "Bearer #{non_admin.generate_api_token!}" }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns the ordered Step/Run waterfall for a workflow" do
      enable_plugin!
      workflow = Workflow.create!(
        job: job, trigger_kind: "initial", state: "running",
        started_at: 20.minutes.ago, worker_hostname: "worker-a"
      )
      prepare_step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 20.minutes.ago, finished_at: 19.minutes.ago)
      implement_step = workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 19.minutes.ago)
      run = Run.create!(
        job: job, user: admin, step: implement_step, trigger_kind: "initial", agent_provider: "claude",
        state: "running", started_at: 19.minutes.ago
      )

      get "/api/v1/admin/worker_timeline/workflow", params: { id: workflow.id }, headers: auth

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.dig("workflow", "id")).to eq(workflow.id)
      expect(body.dig("workflow", "hostname")).to eq("worker-a")
      expect(body.fetch("steps").map { |step| step["id"] }).to eq([ prepare_step.id, implement_step.id ])
      expect(body.dig("steps", 1, "runs", 0, "id")).to eq(run.id)
    end

    it "404s for an unknown workflow id" do
      enable_plugin!

      get "/api/v1/admin/worker_timeline/workflow", params: { id: 999_999_999 }, headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end
end
