require "rails_helper"

RSpec.describe RunQueueResolver, :ci_only do
  let(:job) { Factories.job }

  def mutable_run_with_storage(storage_key)
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      worker_storage_key: storage_key
    )
    step = Step.create!(
      workflow: workflow,
      kind: "summarize",
      position: 1,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )

    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
  end

  def solid_queue_worker(hostname, queues: "runs")
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "Worker",
      name: "#{hostname}-#{SecureRandom.hex(4)}",
      pid: 123,
      last_heartbeat_at: Time.current,
      metadata: {
        "queues" => queues,
        "polling_interval" => 0.1,
        "pool_size" => 1
      }
    )
  end

  def instance_version(hostname:, role: "worker", capabilities:, **attributes)
    InstanceVersion.create!({
      hostname: hostname,
      role: role,
      version: "abc123",
      started_at: 1.minute.ago,
      last_heartbeat_at: Time.current,
      capabilities: capabilities
    }.merge(attributes))
  end

  it "preserves a live storage-affinity queue for default mutable retries when no capability payload is available" do
    run = mutable_run_with_storage("storage-main")
    queue = "resume-storage-main"
    allow(InstanceVersion).to receive(:worker_queue_live?).with(queue).and_return(true)

    decision = described_class.resolve(run: run)

    expect(decision.queue_name).to eq(queue)
    expect(decision.sticky_resume).to eq(true)
    expect(decision).not_to be_blocked
  end

  # A draining worker still heartbeats but never claims again, so offering it
  # as a routing target strands whatever is sent to its private queue.
  it "does not offer a draining worker as a live routing target" do
    ensure_solid_queue_test_tables!
    %w[compute-old compute-new].each do |hostname|
      process = SolidQueue::Process.create!(
        hostname: hostname, kind: "Worker", name: "#{hostname}-1", pid: 123, last_heartbeat_at: Time.current,
        metadata: { "queues" => "worker-#{hostname},runs", "polling_interval" => 0.1, "pool_size" => 1 }
      )
      Syrus::QueueDrain.mark!(process) if hostname == "compute-old"
    end
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "summarize", position: 1)
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)

    hostnames = Array(described_class.resolve(run: run).details["live_workers"]).map { |worker| worker["hostname"] }

    expect(hostnames).to include("compute-new")
    expect(hostnames).not_to include("compute-old")
  end

  it "uses the process hostname column when worker metadata omits capability identity" do
    ensure_solid_queue_test_tables!
    instance = InstanceVersion.create!(
      hostname: "mac-worker",
      role: "worker",
      version: "abc123",
      started_at: 1.minute.ago,
      last_heartbeat_at: Time.current,
      capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] }
    )
    SolidQueue::Process.create!(
      hostname: instance.hostname,
      kind: "Worker",
      name: "worker-1",
      pid: 123,
      last_heartbeat_at: Time.current,
      metadata: {
        "queues" => "runs-macos-arm64",
        "polling_interval" => 0.1,
        "pool_size" => 1
      }
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      planned_execution_capabilities: { "os" => [ "macos" ] }
    )
    step = Step.create!(
      workflow: workflow,
      kind: "prepare",
      position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)

    decision = described_class.resolve(run: run)

    expect(decision.queue_name).to eq("runs-macos-arm64")
    expect(decision).not_to be_blocked
  end

  describe "macOS worker release skew" do
    def mac_run
      workflow = Workflow.create!(job: job, trigger_kind: "initial", planned_execution_capabilities: { "os" => [ "macos" ] })
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0,
        placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE)
      step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)
    end

    before do
      ensure_solid_queue_test_tables!
      solid_queue_worker("mac-worker", queues: "runs-macos-arm64")
      AppSetting.current.update!(macos_worker_desired_release: { "git_sha" => "50d35be290", "rollout" => "immediate" })
    end

    # Regression: a deploy migrated the database, and a Mac worker still on
    # the previous revision took Runs and failed them on a table that the
    # migration had dropped.
    it "does not count a Mac worker on another revision than the active release as capacity" do
      instance_version(hostname: "mac-worker", version: "16254d1666", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] })

      decision = described_class.resolve(run: mac_run)

      worker = decision.details.fetch("live_workers").find { |w| w["hostname"] == "mac-worker" }
      expect(worker).to include("eligible" => false, "version_skew" => true)
      expect(decision).to be_blocked
    end

    it "routes to a Mac worker that runs the active release, whatever abbreviation it reports" do
      instance_version(hostname: "mac-worker", version: "50d35be290a1", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] })

      decision = described_class.resolve(run: mac_run)

      expect(decision.queue_name).to eq("runs-macos-arm64")
      expect(decision).not_to be_blocked
    end
  end

  it "bulk-loads fresh worker instances once for multiple admission candidates and keeps hosts distinct" do
    ensure_solid_queue_test_tables!
    solid_queue_worker("worker-a", queues: "runs-macos-arm64")
    solid_queue_worker("worker-b", queues: "runs-macos-arm64")
    instance_version(hostname: "worker-a", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] })
    instance_version(hostname: "worker-b", capabilities: { "os" => [ "linux" ], "arch" => [ "amd64" ] })
    instance_version(hostname: "worker-a", role: "web", capabilities: { "os" => [ "linux" ], "arch" => [ "amd64" ] })
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      planned_execution_capabilities: { "os" => [ "macos" ] }
    )
    step = Step.create!(
      workflow: workflow,
      kind: "prepare",
      position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)
    instance_loads = []
    subscriber = ->(*, payload) { instance_loads << payload[:sql] if payload[:name] == "InstanceVersion Load" }

    decision = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.resolve(run: run)
    end

    workers = decision.details
      .fetch("live_workers")
      .select { |worker| worker.fetch("selected_queue") }
      .index_by { |worker| worker.fetch("hostname") }
    expect(instance_loads.size).to eq(1)
    expect(workers.fetch("worker-a")).to include(
      "eligible" => true,
      "capabilities" => { "os" => [ "macos" ], "arch" => [ "arm64" ] }
    )
    expect(workers.fetch("worker-b")).to include(
      "eligible" => false,
      "capabilities" => { "os" => [ "linux" ], "arch" => [ "amd64" ] }
    )
    expect(decision).not_to be_blocked
  end

  it "does not use stale or finished worker instances during bulk admission lookup" do
    ensure_solid_queue_test_tables!
    solid_queue_worker("stale-worker", queues: "runs-macos-arm64")
    solid_queue_worker("finished-worker", queues: "runs-macos-arm64")
    instance_version(
      hostname: "stale-worker",
      capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] },
      started_at: 10.minutes.ago,
      last_heartbeat_at: 3.minutes.ago
    )
    instance_version(
      hostname: "finished-worker",
      capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] },
      finished_at: Time.current
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      planned_execution_capabilities: { "os" => [ "macos" ] }
    )
    step = Step.create!(
      workflow: workflow,
      kind: "prepare",
      position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)

    decision = described_class.resolve(run: run)

    workers = decision.details.fetch("live_workers").index_by { |worker| worker.fetch("hostname") }
    expect(workers.fetch("stale-worker")).to include("eligible" => false, "capabilities" => {})
    expect(workers.fetch("finished-worker")).to include("eligible" => false, "capabilities" => {})
    expect(decision).to be_blocked
  end

  it "uses the newest host health sample when a worker has multiple fresh samples" do
    ensure_solid_queue_test_tables!
    now = Time.current
    SolidQueue::Process.create!(
      hostname: "worker-a",
      kind: "Worker",
      name: "worker-1",
      pid: 123,
      last_heartbeat_at: now,
      metadata: {
        "queues" => "runs",
        "polling_interval" => 0.1,
        "pool_size" => 1
      }
    )
    WorkerHostHealthSample.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      worker_storage_key: "storage-old",
      observed_at: now - 2.minutes,
      cpu_used_percent: 10,
      capability_diagnostics: { "docker" => false }
    )
    WorkerHostHealthSample.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      worker_storage_key: "storage-new",
      observed_at: now - 1.minute,
      cpu_used_percent: 10,
      capability_diagnostics: { "docker" => true }
    )
    run = mutable_run_with_storage(nil)

    decision = described_class.resolve(run: run)
    live_worker = decision.details.fetch("live_workers").find { |worker| worker.fetch("hostname") == "worker-a" }

    expect(live_worker).to include(
      "worker_storage_key" => "storage-new",
      "capability_diagnostics" => { "docker" => true }
    )
  end
end
