require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/worker_timeline", type: :request do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Fix the aqueducts") }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    PluginRecord.find_or_create_by!(name: "worker_timeline").update!(enabled: true, disableable: true)
  end

  describe "GET /macro" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to Timeline::MacroQuery with filters parsed from the shared FilterBar's q param, for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      other_repository = Factories.repository(user: admin)
      other_job = Factories.job_record(user: admin, repository: other_repository, state: "running")
      infrastructure_job = Factories.job_record(user: admin, repository: repository, state: "running", kind: "main_grader", issue_number: nil)

      matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: infrastructure_job, trigger_kind: "main_grader", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")

      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => repository.id },
          { "field" => "hostname", "op" => "is", "value" => "worker-x" },
          { "field" => "status", "op" => "is_one_of", "value" => [ "running" ] },
          { "field" => "job_type", "op" => "is_one_of", "value" => [ "user" ] }
        ]
      )

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ matching.id ])
      expect(spans.first.fetch("job_title")).to eq("Fix the aqueducts")
      expect(parse_body.fetch("filter")).to eq(Filters::QueryParam.decode(q))
    end

    it "defaults to the last 3 hours with no filters applied when no q param is given" do
      enable_plugin!
      sign_in_as(admin)

      recent = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 2.hours.ago, worker_hostname: "worker-x")
      Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", started_at: 4.hours.ago, finished_at: 3.5.hours.ago, worker_hostname: "worker-x")

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ recent.id ])
      expect(parse_body.fetch("filter")).to eq({ "and" => [] })

      from = Time.iso8601(parse_body.dig("range", "from"))
      to = Time.iso8601(parse_body.dig("range", "to"))
      expect(to - from).to be_within(5).of(3.hours)
    end

    it "computes the time window from a within_last window chip" do
      enable_plugin!
      sign_in_as(admin)

      recent = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 20.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", started_at: 2.hours.ago, finished_at: 90.minutes.ago, worker_hostname: "worker-x")

      q = Filters::QueryParam.encode("and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "minutes" } } ])

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ recent.id ])
    end

    it "includes the filter_schema the shared FilterBar renders against" do
      enable_plugin!
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(
        %w[ repository_id epic_id hostname job_type status window ]
      )
    end
  end

  describe "GET /workflow" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: 1 }

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: 1 }

      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to Timeline::WorkflowWaterfallQuery for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-a")
      step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: workflow.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("workflow", "id")).to eq(workflow.id)
      expect(parse_body.fetch("steps").map { |payload| payload.fetch("id") }).to eq([ step.id ])
    end

    it "404s for an unknown workflow id" do
      enable_plugin!
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: -1 }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /live" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/live"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/live"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns multi-slot hosts, idle hosts, health states, and redacted commands" do
      enable_plugin!
      sign_in_as(admin)
      busy_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Repair the fountain")
      busy_workflow = Workflow.create!(job: busy_job, trigger_kind: "initial", state: "running", started_at: 12.minutes.ago, worker_hostname: "worker-a", worker_storage_key: "storage-a")
      busy_step = busy_workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 11.minutes.ago)
      busy_run = Run.create!(job: busy_job, user: admin, step: busy_step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 10.minutes.ago)
      SpawnedProcess.create!(
        kind: "agent",
        command: "git fetch https://x-access-token:ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@github.com/acme/widgets && echo ok",
        hostname: "worker-a",
        pid: 901,
        started_at: 9.minutes.ago,
        run: busy_run,
        workflow: busy_workflow
      )
      solid_queue_process(hostname: "worker-a", pid: 101, metadata: { "queues" => "runs,maintenance", "thread_pool_size" => 2 })
      solid_queue_process(hostname: "worker-idle", pid: 102, metadata: { "queues" => [ "runs" ], "thread_pool_size" => 1 })
      solid_queue_process(hostname: "worker-hot", pid: 103, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      2.times do |index|
        hot_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Hot job #{index}")
        hot_workflow = Workflow.create!(job: hot_job, trigger_kind: "retry", state: "running", started_at: (8 - index).minutes.ago, worker_hostname: "worker-hot", worker_storage_key: "storage-hot")
        hot_step = hot_workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: (7 - index).minutes.ago)
        Run.create!(job: hot_job, user: admin, step: hot_step, trigger_kind: "retry", agent_provider: "codex", state: "running", started_at: (6 - index).minutes.ago)
      end
      create_health_sample(hostname: "worker-a", worker_storage_key: "storage-a", cpu_used_percent: 25, memory_used_percent: 35, io_pressure_some: 2)
      create_health_sample(hostname: "worker-idle", worker_storage_key: "storage-idle", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 0)
      create_health_sample(hostname: "worker-hot", worker_storage_key: "storage-hot", cpu_used_percent: 99, memory_used_percent: 96, io_pressure_some: 60)

      get "/api/v1/app/admin/worker_timeline/live"

      expect(response).to have_http_status(:ok)
      workers = parse_body.fetch("workers").index_by { |worker| worker.fetch("hostname") }
      expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(%w[ hostname status window ])
      expect(parse_body.dig("attribution", "exact_thread_ownership")).to be(false)
      expect(workers.fetch("worker-a").dig("occupancy")).to eq("used" => 1, "total" => 2)
      expect(workers.fetch("worker-idle").fetch("status")).to eq("idle")
      expect(workers.fetch("worker-hot").fetch("status")).to eq("overloaded")
      expect(workers.fetch("worker-hot").dig("occupancy")).to eq("used" => 2, "total" => 1)
      slot = workers.fetch("worker-a").fetch("pools").first.fetch("slots").first
      expect(slot).to include("job_slug" => busy_job.slug, "workflow_id" => busy_workflow.id, "step_kind" => "implement", "run_id" => busy_run.id, "pid" => 901, "process_kind" => "agent")
      expect(slot.fetch("command_excerpt")).to include("[REDACTED]")
      expect(slot.fetch("command_excerpt")).not_to include("ghp_")
    end

    it "assigns each inferred slot to at most one matching worker pool" do
      enable_plugin!
      sign_in_as(admin)
      solid_queue_process(hostname: "worker-a", pid: 101, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      solid_queue_process(hostname: "worker-a", pid: 102, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      create_health_sample(hostname: "worker-a", worker_storage_key: "storage-a", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 0)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-a", worker_storage_key: "storage-a")
      step = workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 9.minutes.ago)
      Run.create!(job: job, user: admin, step: step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 8.minutes.ago)

      get "/api/v1/app/admin/worker_timeline/live"

      expect(response).to have_http_status(:ok)
      worker = parse_body.fetch("workers").find { |entry| entry.fetch("hostname") == "worker-a" }
      expect(worker.dig("occupancy")).to eq("used" => 1, "total" => 2)
      expect(worker.fetch("pools").sum { |pool| pool.fetch("slots").length }).to eq(1)
      expect(worker.fetch("pools").map { |pool| pool.fetch("used") }).to contain_exactly(1, 0)
    end

    it "filters live workers by status from the shared FilterBar q param" do
      enable_plugin!
      sign_in_as(admin)
      solid_queue_process(hostname: "worker-idle", pid: 102, metadata: { "queues" => [ "runs" ], "thread_pool_size" => 1 })
      create_health_sample(hostname: "worker-idle", worker_storage_key: "storage-idle", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 0)
      solid_queue_process(hostname: "worker-busy", pid: 103, metadata: { "queues" => [ "runs" ], "thread_pool_size" => 1 })
      busy_workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-busy", worker_storage_key: "storage-busy")
      busy_step = busy_workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 9.minutes.ago)
      Run.create!(job: job, user: admin, step: busy_step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 8.minutes.ago)
      create_health_sample(hostname: "worker-busy", worker_storage_key: "storage-busy", cpu_used_percent: 15, memory_used_percent: 25, io_pressure_some: 1)
      q = Filters::QueryParam.encode("and" => [ { "field" => "status", "op" => "is_one_of", "value" => [ "busy" ] } ])

      get "/api/v1/app/admin/worker_timeline/live", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("workers").map { |worker| worker.fetch("hostname") }).to eq([ "worker-busy" ])
      expect(parse_body.fetch("filter")).to eq(Filters::QueryParam.decode(q))
    end
  end

  def solid_queue_process(kind: "Worker", hostname:, pid:, metadata: {}, last_heartbeat_at: Time.current)
    SolidQueue::Process.create!(kind: kind, name: "#{kind.downcase}-#{pid}", hostname: hostname, pid: pid, last_heartbeat_at: last_heartbeat_at, created_at: Time.current, metadata: metadata)
  end

  def create_health_sample(hostname:, worker_storage_key:, cpu_used_percent:, memory_used_percent:, io_pressure_some:)
    WorkerHostHealthSample.create!(hostname: hostname, worker_storage_key: worker_storage_key, role: "worker", version: "abc123", observed_at: 1.minute.ago, cpu_used_percent: cpu_used_percent, memory_used_percent: memory_used_percent, io_pressure_some: io_pressure_some)
  end
end
