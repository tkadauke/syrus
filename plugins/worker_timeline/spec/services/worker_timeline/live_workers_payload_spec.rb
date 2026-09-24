require "rails_helper"

RSpec.describe WorkerTimeline::LiveWorkersPayload do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }

  before do
    PluginRecord.find_or_create_by!(name: "worker_timeline").update!(enabled: true, disableable: true)
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
  end

  around do |example|
    travel_to Time.zone.parse("2026-09-24 12:00:00 UTC") do
      example.run
    end
  end

  after do
    clear_solid_queue_test_tables!
  end

  def payload(filter = WorkerTimeline::MacroQueryFilter.from_params({}))
    described_class.call(filter: filter)
  end

  def worker_instance!(hostname:, storage_key: nil, cpu: 20, memory: 30, io: 1, observed_at: Time.current)
    InstanceVersion.create!(
      hostname: hostname,
      role: "worker",
      version: "abc123",
      started_at: 10.minutes.ago,
      last_heartbeat_at: 20.seconds.ago
    )
    WorkerHostHealthSample.create!(
      hostname: hostname,
      worker_storage_key: storage_key,
      role: "worker",
      version: "abc123",
      observed_at: observed_at,
      cpu_used_percent: cpu,
      memory_used_percent: memory,
      io_pressure_some: io
    )
  end

  def pool!(hostname:, pid:, queues: [ "runs" ], threads: 1)
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "Worker",
      last_heartbeat_at: Time.current,
      metadata: { "queues" => queues, "thread_pool_size" => threads },
      name: "#{hostname}:#{pid}",
      pid: pid,
      created_at: Time.current
    )
  end

  def running_slot!(hostname:, pid:, command: "codex exec", epic: nil)
    job = Factories.job_record(user: admin, repository: repository, epic: epic, state: "running", issue_title: "Repair the scheduler")
    workflow = Workflow.create!(job: job, user: admin, trigger_kind: "initial", state: "running", started_at: 4.minutes.ago, chain_template: "initial")
    step = workflow.steps.create!(kind: "implement", position: 0, state: "running", started_at: 4.minutes.ago)
    run = Run.create!(job: job, user: admin, step: step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 4.minutes.ago)
    SpawnedProcess.create!(
      kind: "agent",
      command: command,
      hostname: hostname,
      pid: pid,
      started_at: 3.minutes.ago,
      run: run
    )
  end

  def filter_tree(tree)
    WorkerTimeline::MacroQueryFilter.from_params(q: Filters::QueryParam.encode(tree))
  end

  it "groups multiple running slots under one worker storage identity" do
    worker_instance!(hostname: "worker-a", storage_key: "storage-a")
    pool!(hostname: "worker-a", pid: 100, queues: [ "runs", "maintenance" ], threads: 3)
    running_slot!(hostname: "worker-a", pid: 201)
    running_slot!(hostname: "worker-a", pid: 202)

    host = payload.fetch(:hosts).sole

    expect(host).to include(
      key: "storage-a",
      hostname: "worker-a",
      worker_storage_key: "storage-a",
      state: "busy"
    )
    expect(host.fetch(:pools).first).to include(queues: [ "runs", "maintenance" ], threads: 3)
    expect(host.fetch(:slots).map { |slot| slot.dig(:spawned_process, :pid) }).to eq([ 201, 202 ])
    expect(payload.dig(:summary, :active_slots)).to eq(2)
    expect(payload.dig(:summary, :total_slots)).to eq(3)
  end

  it "includes idle worker hosts with queue pools and no active slots" do
    worker_instance!(hostname: "worker-idle", storage_key: "storage-idle")
    pool!(hostname: "worker-idle", pid: 300, threads: 2)

    host = payload.fetch(:hosts).sole

    expect(host).to include(state: "idle")
    expect(host.fetch(:slots)).to eq([])
    expect(host.fetch(:pools).first).to include(pid: 300, threads: 2)
    expect(payload.dig(:summary, :idle_hosts)).to eq(1)
  end

  it "marks hosts overloaded from occupancy beyond pool capacity and degraded from health pressure" do
    worker_instance!(hostname: "worker-full", storage_key: "storage-full")
    pool!(hostname: "worker-full", pid: 400, threads: 1)
    running_slot!(hostname: "worker-full", pid: 401)
    running_slot!(hostname: "worker-full", pid: 402)

    worker_instance!(hostname: "worker-hot", storage_key: "storage-hot", cpu: 91)
    pool!(hostname: "worker-hot", pid: 500, threads: 3)

    states = payload.fetch(:hosts).to_h { |host| [ host.fetch(:key), host.fetch(:state) ] }

    expect(states).to include(
      "storage-full" => "overloaded",
      "storage-hot" => "degraded"
    )
  end

  it "redacts command excerpts and labels attribution uncertainty" do
    worker_instance!(hostname: "worker-a", storage_key: "storage-a")
    pool!(hostname: "worker-a", pid: 100, threads: 2)
    running_slot!(hostname: "worker-a", pid: 201, command: "git clone https://x-access-token:ghp_secret1234567890@github.com/acme/widgets")
    SpawnedProcess.create!(
      kind: "git",
      command: "git status",
      hostname: "worker-a",
      pid: 301,
      started_at: 2.minutes.ago
    )

    slots = payload.fetch(:hosts).sole.fetch(:slots)

    expect(slots.first.dig(:spawned_process, :command_excerpt)).to include("[REDACTED]")
    expect(slots.first.fetch(:attribution_confidence)).to eq("run")
    expect(slots.second.fetch(:attribution_confidence)).to eq("process")
    expect(slots.second.fetch(:attribution_note)).to include("exact thread ownership is not instrumented")
  end

  it "falls back to active Run and Workflow state when no subprocess is linked" do
    worker_instance!(hostname: "worker-a", storage_key: "storage-a")
    pool!(hostname: "worker-a", pid: 100, threads: 2)
    job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Continue without a child process")
    workflow = Workflow.create!(
      job: job,
      user: admin,
      trigger_kind: "retry",
      state: "running",
      started_at: 4.minutes.ago,
      worker_hostname: "worker-a",
      worker_storage_key: "storage-a"
    )
    step = workflow.steps.create!(kind: "implement", position: 0, state: "running", started_at: 4.minutes.ago)
    run = Run.create!(job: job, user: admin, step: step, trigger_kind: "retry", agent_provider: "codex", state: "running", started_at: 3.minutes.ago)

    slot = payload.fetch(:hosts).sole.fetch(:slots).sole

    expect(slot).to include(id: "run-#{run.id}", attribution_confidence: "run_state")
    expect(slot.dig(:workflow, :id)).to eq(workflow.id)
    expect(slot.dig(:spawned_process, :command_excerpt)).to eq("No running subprocess is currently linked.")
  end

  it "shows an active Run host even before health samples or queue pools exist" do
    job = Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Start on a new worker")
    workflow = Workflow.create!(
      job: job,
      user: admin,
      trigger_kind: "initial",
      state: "running",
      started_at: 1.minute.ago,
      worker_hostname: "worker-new",
      worker_storage_key: "storage-new"
    )
    step = workflow.steps.create!(kind: "prepare", position: 0, state: "running", started_at: 1.minute.ago)
    Run.create!(job: job, user: admin, step: step, trigger_kind: "initial", agent_provider: "codex", state: "running", started_at: 1.minute.ago)

    host = payload.fetch(:hosts).sole

    expect(host).to include(key: "storage-new", hostname: "worker-new", state: "degraded")
    expect(host.dig(:health, :level)).to eq("unknown")
    expect(host.fetch(:pools)).to eq([])
    expect(host.fetch(:slots).sole.fetch(:attribution_confidence)).to eq("run_state")
  end

  it "hides unrelated idle hosts when a repository filter scopes live workers" do
    worker_instance!(hostname: "worker-a", storage_key: "storage-a")
    worker_instance!(hostname: "worker-idle", storage_key: "storage-idle")
    pool!(hostname: "worker-a", pid: 100, threads: 2)
    pool!(hostname: "worker-idle", pid: 200, threads: 2)
    running_slot!(hostname: "worker-a", pid: 201)

    body = payload(filter_tree("and" => [ { "field" => "repository_id", "op" => "is", "value" => repository.id } ]))

    expect(body.fetch(:hosts).map { |host| host.fetch(:key) }).to eq([ "storage-a" ])
  end

  it "hides unrelated idle hosts when an epic filter scopes live workers" do
    epic = Factories.epic(user: admin, repository: repository)
    worker_instance!(hostname: "worker-epic", storage_key: "storage-epic")
    worker_instance!(hostname: "worker-idle", storage_key: "storage-idle")
    pool!(hostname: "worker-epic", pid: 100, threads: 2)
    pool!(hostname: "worker-idle", pid: 200, threads: 2)
    running_slot!(hostname: "worker-epic", pid: 201, epic: epic)

    body = payload(filter_tree("and" => [ { "field" => "epic_id", "op" => "is", "value" => epic.id } ]))

    expect(body.fetch(:hosts).map { |host| host.fetch(:key) }).to eq([ "storage-epic" ])
  end

  it "hides unrelated idle hosts when a job type filter scopes live workers" do
    worker_instance!(hostname: "worker-user", storage_key: "storage-user")
    worker_instance!(hostname: "worker-idle", storage_key: "storage-idle")
    pool!(hostname: "worker-user", pid: 100, threads: 2)
    pool!(hostname: "worker-idle", pid: 200, threads: 2)
    running_slot!(hostname: "worker-user", pid: 201)

    body = payload(filter_tree("and" => [ { "field" => "job_type", "op" => "is_one_of", "value" => [ "user" ] } ]))

    expect(body.fetch(:hosts).map { |host| host.fetch(:key) }).to eq([ "storage-user" ])
  end
end
