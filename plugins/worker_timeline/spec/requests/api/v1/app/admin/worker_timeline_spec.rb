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

    it "evaluates nested boolean groups instead of flattening them" do
      enable_plugin!
      sign_in_as(admin)
      matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      excluded = Workflow.create!(job: job, trigger_kind: "retry", state: "failed", started_at: 9.minutes.ago, worker_hostname: "worker-y")
      q = Filters::QueryParam.encode(
        "and" => [
          { "or" => [
            { "field" => "hostname", "op" => "is", "value" => "worker-x" },
            { "field" => "status", "op" => "is_one_of", "value" => [ "succeeded" ] }
          ] },
          { "not" => { "field" => "status", "op" => "is_one_of", "value" => [ "failed" ] } }
        ]
      )

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      ids = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }
      expect(ids).to contain_exactly(matching.id)
      expect(ids).not_to include(excluded.id)
    end

    it "applies one OR expression consistently to pending workflows and idle lanes" do
      enable_plugin!
      sign_in_as(admin)
      pending = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
      InstanceVersion.create!(hostname: "worker-idle", role: "worker", version: "abc123",
                              started_at: 1.hour.ago, last_heartbeat_at: 1.minute.ago)
      q = Filters::QueryParam.encode("or" => [
        { "field" => "status", "op" => "is_one_of", "value" => [ "queued" ] },
        { "field" => "hostname", "op" => "is", "value" => "worker-idle" }
      ])

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(parse_body.fetch("pending").map { |entry| entry.fetch("workflow_id") }).to include(pending.id)
      idle_lane = parse_body.fetch("lanes").find { |lane| lane.fetch("hostname") == "worker-idle" }
      expect(idle_lane).to include("spans" => [])
    end

    it "enforces repository visibility before evaluating the expression" do
      enable_plugin!
      sign_in_as(admin)
      another_user = Factories.user
      hidden_repository = Factories.repository(user: another_user)
      hidden_job = Factories.job_record(user: another_user, repository: hidden_repository, state: "running")
      hidden = Workflow.create!(job: hidden_job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago, worker_hostname: "worker-secret")
      q = Filters::QueryParam.encode("and" => [ { "not" => { "field" => "hostname", "op" => "is", "value" => "nobody" } } ])

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      ids = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }
      expect(ids).not_to include(hidden.id)
    end

    it "uses a saved folder, allows a URL override, and exposes navigation metadata" do
      enable_plugin!
      sign_in_as(admin)
      running = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      failed = Workflow.create!(job: job, trigger_kind: "retry", state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago, worker_hostname: "worker-x")
      folder = SmartFolder.create!(user: admin, name: "Failures", kind: "user_defined", subject_type: "worker_timeline", position: 0,
                                   filter: { "and" => [ { "field" => "status", "op" => "is_one_of", "value" => [ "failed" ] } ] })

      get "/api/v1/app/admin/worker_timeline/macro", params: { smart_folder_id: folder.id }
      expect(parse_body.fetch("active_smart_folder_id")).to eq(folder.id)
      expect(parse_body.fetch("smart_folders").first).to include("id" => folder.id, "path" => "/worker_timeline?smart_folder_id=#{folder.id}")
      expect(parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }).to eq([ failed.id ])

      q = Filters::QueryParam.encode("and" => [ { "field" => "status", "op" => "is_one_of", "value" => [ "running" ] } ])
      get "/api/v1/app/admin/worker_timeline/macro", params: { smart_folder_id: folder.id, q: q }
      expect(parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }).to eq([ running.id ])
    end

    it "rejects unsupported saved predicates clearly" do
      enable_plugin!
      sign_in_as(admin)
      q = Filters::QueryParam.encode("and" => [ { "field" => "hostname", "op" => "contains", "value" => "worker" } ])

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_filter")
      expect(parse_body.dig("error", "message")).to include("unsupported operator")
    end
  end

  describe "Worker Timeline smart folder CRUD" do
    let(:filter) { { "and" => [ { "field" => "hostname", "op" => "is", "value" => "worker-a" } ] } }

    before do
      enable_plugin!
      sign_in_as(admin)
    end

    it "creates, updates, navigates to, and deletes a saved timeline expression" do
      post "/api/v1/app/smart_folders", params: {
        subject_type: "worker_timeline", filter: filter.to_json,
        smart_folder: { name: "Worker A" }
      }
      expect(response).to have_http_status(:created)
      folder_id = parse_body.dig("smart_folder", "id")
      expect(parse_body.fetch("redirect_to")).to eq("/worker_timeline?smart_folder_id=#{folder_id}")

      replacement = { "or" => [
        { "field" => "hostname", "op" => "is", "value" => "worker-a" },
        { "field" => "hostname", "op" => "is", "value" => "worker-b" }
      ] }
      patch "/api/v1/app/smart_folders/#{folder_id}", params: {
        filter: replacement.to_json, smart_folder: { name: "Primary workers", position: 1 }
      }
      expect(response).to have_http_status(:ok)
      expect(SmartFolder.find(folder_id)).to have_attributes(name: "Primary workers", filter: replacement)

      delete "/api/v1/app/smart_folders/#{folder_id}"
      expect(response).to have_http_status(:ok)
      expect(SmartFolder.exists?(folder_id)).to be(false)
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
        command: "git fetch https://x-access-token:ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@github.com/acme/widgets && bin/deploy password=super-secret-token",
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
      expect(workers.fetch("worker-a").dig("occupancy")).to include("used" => 1, "total" => 2)
      expect(workers.fetch("worker-idle").fetch("status")).to eq("idle")
      expect(workers.fetch("worker-hot").fetch("status")).to eq("overloaded")
      expect(workers.fetch("worker-hot").dig("occupancy")).to include("used" => 2, "total" => 1)
      slot = workers.fetch("worker-a").fetch("pools").first.fetch("slots").first
      expect(slot).to include("job_slug" => busy_job.slug, "workflow_id" => busy_workflow.id, "step_kind" => "implement", "run_id" => busy_run.id, "pid" => 901, "process_kind" => "agent")
      expect(slot.fetch("command_excerpt")).to include("[REDACTED]")
      expect(slot.fetch("command_excerpt")).not_to include("ghp_")
      expect(slot.fetch("command_excerpt")).not_to include("super-secret-token")
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
      expect(worker.dig("occupancy")).to include("used" => 1, "total" => 2)
      expect(worker.fetch("pools").sum { |pool| pool.fetch("slots").length }).to eq(1)
      expect(worker.fetch("pools").map { |pool| pool.fetch("used") }).to contain_exactly(1, 0)
    end

    # Regression: graders with the immutable_source_checkout placement are not
    # pinned to the workflow's worker -- RunQueueResolver sends them to the
    # shared `runs` queue, so they run wherever there is room. Attributing
    # their slots to the workflow's worker drew a whole workflow's graders
    # onto one card, which read as a single overloaded host beside idle peers
    # while the work was actually spread across all of them.
    it "attributes a spawned process to the host it ran on, not the workflow's worker" do
      enable_plugin!
      sign_in_as(admin)
      spread_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Spread graders")
      spread_workflow = Workflow.create!(job: spread_job, trigger_kind: "main_grader", state: "running",
                                         started_at: 9.minutes.ago, worker_hostname: "worker-origin", worker_storage_key: "storage-origin")
      spread_step = spread_workflow.steps.create!(kind: "grader", position: 1, state: "running", started_at: 8.minutes.ago)
      spread_run = Run.create!(job: spread_job, user: admin, step: spread_step, trigger_kind: "main_grader",
                               agent_provider: "codex", state: "running", started_at: 7.minutes.ago)
      SpawnedProcess.create!(kind: "grader", command: "bin/rspec", hostname: "worker-elsewhere", pid: 4100,
                             started_at: 6.minutes.ago, run: spread_run, workflow: spread_workflow)
      solid_queue_process(hostname: "worker-origin", pid: 120, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      solid_queue_process(hostname: "worker-elsewhere", pid: 121, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      create_health_sample(hostname: "worker-origin", worker_storage_key: "storage-origin", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 0)
      create_health_sample(hostname: "worker-elsewhere", worker_storage_key: "storage-elsewhere", cpu_used_percent: 20, memory_used_percent: 25, io_pressure_some: 0)

      get "/api/v1/app/admin/worker_timeline/live"

      workers = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }
      expect(workers.fetch("worker-elsewhere").dig("occupancy", "used")).to eq(1)
      expect(workers.fetch("worker-origin").dig("occupancy", "used")).to eq(0)
      expect(workers.fetch("worker-origin").fetch("status")).to eq("idle")
    end

    # Regression: occupancy used to count spawned processes against
    # SolidQueue's thread_pool_size. One grader Step spawns a tree of
    # processes -- bundler, the test runner, its parallel workers -- so a
    # worker doing exactly one unit of work reported many slots against a
    # capacity of one and was flagged "overloaded" while nearly idle. A real
    # host read 15/2 at 15% CPU.
    it "counts one busy thread per Run, not one per spawned process" do
      enable_plugin!
      sign_in_as(admin)
      noisy_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Noisy grader")
      noisy_workflow = Workflow.create!(job: noisy_job, trigger_kind: "main_grader", state: "running",
                                        started_at: 9.minutes.ago, worker_hostname: "worker-noisy", worker_storage_key: "storage-noisy")
      noisy_step = noisy_workflow.steps.create!(kind: "grader", position: 1, state: "running", started_at: 8.minutes.ago)
      noisy_run = Run.create!(job: noisy_job, user: admin, step: noisy_step, trigger_kind: "main_grader",
                              agent_provider: "codex", state: "running", started_at: 7.minutes.ago)
      6.times do |index|
        SpawnedProcess.create!(kind: "grader", command: "bin/rspec worker #{index}", hostname: "worker-noisy",
                               pid: 2000 + index, started_at: 6.minutes.ago, run: noisy_run, workflow: noisy_workflow)
      end
      solid_queue_process(hostname: "worker-noisy", pid: 110, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      create_health_sample(hostname: "worker-noisy", worker_storage_key: "storage-noisy", cpu_used_percent: 15, memory_used_percent: 30, io_pressure_some: 1)

      get "/api/v1/app/admin/worker_timeline/live"

      worker = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }.fetch("worker-noisy")
      expect(worker.dig("occupancy", "used")).to eq(1)
      expect(worker.dig("occupancy", "total")).to eq(1)
      expect(worker.fetch("status")).to eq("busy")
      expect(worker.fetch("status_reasons")).not_to include("capacity exceeded")
    end

    # Regression: capacity was read from `thread_pool_size`, a key SolidQueue
    # has never written -- it records `pool_size`. Every pool therefore
    # resolved to nil, was clamped to 1, and a host running pools of 3 and 5
    # threads reported a capacity of 2. The fixtures in this file used the
    # wrong key too, so the specs agreed with the code and both disagreed with
    # production.
    it "reads pool capacity from the key SolidQueue actually writes" do
      enable_plugin!
      sign_in_as(admin)
      solid_queue_process(hostname: "worker-pools", pid: 130, metadata: { "queues" => "runs", "pool_size" => 3 })
      solid_queue_process(hostname: "worker-pools", pid: 131, metadata: { "queues" => "merges", "pool_size" => 5 })
      create_health_sample(hostname: "worker-pools", worker_storage_key: "storage-pools", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 1)

      get "/api/v1/app/admin/worker_timeline/live"

      worker = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }.fetch("worker-pools")
      expect(worker.dig("occupancy", "total")).to eq(8)
    end

    # An unreadable pool size used to become a capacity of 1, which quietly
    # turned "I could not read this" into an overload claim.
    it "does not claim a host is over capacity when the pool size is unreadable" do
      enable_plugin!
      sign_in_as(admin)
      j = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Unknown pool")
      wf = Workflow.create!(job: j, trigger_kind: "main_grader", state: "running", started_at: 9.minutes.ago,
                            worker_hostname: "worker-unknown", worker_storage_key: "storage-unknown")
      st = wf.steps.create!(kind: "grader", position: 1, state: "running", started_at: 8.minutes.ago)
      # Two distinct Runs, so occupancy is 2 and the old clamp-to-1 capacity
      # would have read as over capacity.
      2.times do |index|
        run = Run.create!(job: j, user: admin, step: st, trigger_kind: "main_grader", agent_provider: "codex",
                          state: "running", started_at: 7.minutes.ago)
        SpawnedProcess.create!(kind: "grader", command: "bin/rspec #{index}", hostname: "worker-unknown",
                               pid: 2100 + index, started_at: 6.minutes.ago, run: run, workflow: wf)
      end
      solid_queue_process(hostname: "worker-unknown", pid: 140, metadata: { "queues" => "runs" })
      create_health_sample(hostname: "worker-unknown", worker_storage_key: "storage-unknown", cpu_used_percent: 12, memory_used_percent: 25, io_pressure_some: 1)

      get "/api/v1/app/admin/worker_timeline/live"

      worker = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }.fetch("worker-unknown")
      expect(worker.fetch("status")).to eq("busy")
      expect(worker.fetch("status_reasons")).not_to include("capacity exceeded")
    end

    # Regression: a Workflow assigned to a host but not executing anything was
    # counted as an occupied thread. A burst of Jobs pins many running
    # Workflows to a host while only a few Runs execute cluster-wide, so five
    # of six hosts read "overloaded" at flat CPU and memory.
    it "counts assigned-but-waiting workflows as busy, not as occupied capacity" do
      enable_plugin!
      sign_in_as(admin)
      solid_queue_process(hostname: "worker-waiting", pid: 150, metadata: { "queues" => "runs", "pool_size" => 2 })
      create_health_sample(hostname: "worker-waiting", worker_storage_key: "storage-waiting", cpu_used_percent: 8, memory_used_percent: 22, io_pressure_some: 1)
      4.times do |index|
        waiting_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Waiting #{index}")
        Workflow.create!(job: waiting_job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago,
                         worker_hostname: "worker-waiting", worker_storage_key: "storage-waiting")
      end

      get "/api/v1/app/admin/worker_timeline/live"

      worker = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }.fetch("worker-waiting")
      expect(worker.dig("occupancy", "used")).to eq(0)
      expect(worker.dig("occupancy", "slots")).to eq(4)
      expect(worker.fetch("status")).not_to eq("overloaded")
      expect(worker.fetch("status_reasons")).not_to include("capacity exceeded")
    end

    # The raw count is still worth showing; it just is not an occupancy figure.
    it "still reports how many slots those processes occupy" do
      enable_plugin!
      sign_in_as(admin)
      j = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Slot count")
      wf = Workflow.create!(job: j, trigger_kind: "main_grader", state: "running", started_at: 9.minutes.ago,
                            worker_hostname: "worker-count", worker_storage_key: "storage-count")
      st = wf.steps.create!(kind: "grader", position: 1, state: "running", started_at: 8.minutes.ago)
      run = Run.create!(job: j, user: admin, step: st, trigger_kind: "main_grader", agent_provider: "codex",
                        state: "running", started_at: 7.minutes.ago)
      3.times { |i| SpawnedProcess.create!(kind: "grader", command: "cmd #{i}", hostname: "worker-count", pid: 3000 + i, started_at: 6.minutes.ago, run: run, workflow: wf) }
      solid_queue_process(hostname: "worker-count", pid: 111, metadata: { "queues" => "runs", "thread_pool_size" => 1 })
      create_health_sample(hostname: "worker-count", worker_storage_key: "storage-count", cpu_used_percent: 15, memory_used_percent: 30, io_pressure_some: 1)

      get "/api/v1/app/admin/worker_timeline/live"

      worker = parse_body.fetch("workers").index_by { |w| w.fetch("hostname") }.fetch("worker-count")
      expect(worker.dig("occupancy", "slots")).to eq(3)
      expect(worker.dig("occupancy", "used")).to eq(1)
    end

    it "classifies running descendants of terminal workflows as diagnostics instead of live occupancy" do
      enable_plugin!
      sign_in_as(admin)
      solid_queue_process(hostname: "worker-a", pid: 101, metadata: { "queues" => "runs", "thread_pool_size" => 2 })
      create_health_sample(hostname: "worker-a", worker_storage_key: "storage-a", cpu_used_percent: 10, memory_used_percent: 20, io_pressure_some: 0)

      active_workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-a", worker_storage_key: "storage-a")
      active_step = active_workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 9.minutes.ago)
      active_run = Run.create!(job: job, user: admin, step: active_step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 8.minutes.ago)

      stale_job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Already landed")
      stale_workflow = Workflow.create!(job: stale_job, trigger_kind: "initial", state: "failed", started_at: 40.minutes.ago, finished_at: 30.minutes.ago, worker_hostname: "worker-a", worker_storage_key: "storage-a")
      stale_cancelled_step = stale_workflow.steps.create!(kind: "prepare", position: 0, state: "cancelled", started_at: 39.minutes.ago, finished_at: 38.minutes.ago)
      Run.create!(job: stale_job, user: admin, step: stale_cancelled_step, trigger_kind: "initial", agent_provider: "codex", state: "cancelled", started_at: 39.minutes.ago, finished_at: 38.minutes.ago)
      stale_running_step = stale_workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 37.minutes.ago)
      stale_running_run = Run.create!(job: stale_job, user: admin, step: stale_running_step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 36.minutes.ago)
      stale_job.update_columns(state: "closed", closure_reason: "merged", landed_sha: "abc123", finished_at: 25.minutes.ago)

      get "/api/v1/app/admin/worker_timeline/live"

      expect(response).to have_http_status(:ok)
      worker = parse_body.fetch("workers").find { |entry| entry.fetch("hostname") == "worker-a" }
      expect(worker.dig("occupancy")).to include("used" => 1, "total" => 2)
      live_slots = worker.fetch("pools").flat_map { |pool| pool.fetch("slots") }
      expect(live_slots.map { |slot| slot.fetch("run_id") }).to eq([ active_run.id ])
      expect(live_slots.map { |slot| slot.fetch("step_id") }).to eq([ active_step.id ])

      stale_diagnostics = parse_body.dig("diagnostics", "stale_terminal_descendants")
      expect(stale_diagnostics.map { |slot| slot.fetch("id") }).to contain_exactly("stale-run-#{stale_running_run.id}", "stale-step-#{stale_running_step.id}")
      expect(stale_diagnostics).to all(include("attribution" => "stale_terminal_descendant", "workflow_id" => stale_workflow.id, "workflow_state" => "failed", "descendant_state" => "running"))
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
