require "rails_helper"

# A worker whose environment smoke check failed (WorkerEnvironmentSmoke) stops
# being chosen for the work that needs that check -- and only that work.
# ci_only like the rest of the resolver specs: live workers are SolidQueue
# process rows, and the SolidQueue tables are created in-process.
RSpec.describe RunQueueResolver, :ci_only do
  let(:job) { Factories.job }
  let(:repository) { job.repository }

  before { ensure_solid_queue_test_tables! }

  def live_worker(hostname, queues:, capabilities:, failed: nil)
    SolidQueue::Process.create!(
      hostname: hostname, kind: "Worker", name: "#{hostname}-#{SecureRandom.hex(4)}", pid: 123,
      last_heartbeat_at: Time.current, metadata: { "queues" => queues, "polling_interval" => 0.1, "pool_size" => 1 }
    )
    diagnostics = {}
    unless failed.nil?
      diagnostics["environment_smoke"] = {
        "version" => 1, "status" => failed.empty? ? "passed" : "degraded", "failed" => failed,
        "checks" => failed.to_h { |name| [ name, { "status" => "failed", "reason" => "#{name} is broken here" } ] }
      }
    end
    InstanceVersion.create!(
      hostname: hostname, role: "worker", version: "abc123", started_at: 1.minute.ago, last_heartbeat_at: Time.current,
      capabilities: capabilities, capability_diagnostics: diagnostics
    )
  end

  def prepare_run(os: "linux")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", planned_execution_capabilities: { "os" => [ os ] })
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE)
    step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)
  end

  def worker_detail(decision, hostname)
    decision.details.fetch("live_workers").find { |worker| worker["hostname"] == hostname }
  end

  describe "a macOS worker that fails the MySQL client check" do
    let(:mac) { { "os" => [ "macos" ], "arch" => [ "arm64" ] } }

    before { live_worker("mac-worker", queues: "runs-macos-arm64", capabilities: mac, failed: [ "mysql_client" ]) }

    it "is not chosen for a repository whose prepare plan builds mysql2" do
      repository.update!(worker_environment_requirements: %w[bundler mysql_client ruby])

      decision = described_class.resolve(run: prepare_run(os: "macos"))

      expect(decision).to be_blocked
      expect(decision.blocked_reason).to eq("worker_environment_check_failed")
      expect(decision.details.fetch("environment_checks")).to include("mysql_client")
      expect(worker_detail(decision, "mac-worker")).to include(
        "eligible" => false, "environment_check_failures" => { "mysql_client" => "mysql_client is broken here" }
      )
      expect(decision.environment_check_summary).to eq("mac-worker: mysql_client (mysql_client is broken here)")
    end

    it "still takes work that does not need the failed check" do
      repository.update!(worker_environment_requirements: %w[node npm])

      decision = described_class.resolve(run: prepare_run(os: "macos"))

      expect(decision).not_to be_blocked
      expect(worker_detail(decision, "mac-worker")).to include("eligible" => true)
      expect(worker_detail(decision, "mac-worker")).not_to have_key("environment_check_failures")
    end
  end

  it "still chooses a worker that has published no smoke report" do
    live_worker("mac-worker", queues: "runs-macos-arm64", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] })
    repository.update!(worker_environment_requirements: %w[mysql_client])

    expect(described_class.resolve(run: prepare_run(os: "macos"))).not_to be_blocked
  end

  it "reports a missing capability, not an environment failure, when no worker has the capability at all" do
    live_worker("linux-worker", queues: "runs", capabilities: { "os" => [ "linux" ], "arch" => [ "x86_64" ] }, failed: [ "mysql_client" ])
    repository.update!(worker_environment_requirements: %w[mysql_client])

    expect(described_class.resolve(run: prepare_run(os: "macos")).blocked_reason).to eq("no_live_worker_for_capabilities")
  end

  describe "default Linux work on the shared queue" do
    let(:linux) { { "os" => [ "linux" ], "arch" => [ "x86_64" ] } }

    before { repository.update!(worker_environment_requirements: %w[mysql_client]) }

    it "is not blocked while another worker on the queue passes the check" do
      live_worker("compute-broken", queues: "runs", capabilities: linux, failed: [ "mysql_client" ])
      live_worker("compute-healthy", queues: "runs", capabilities: linux, failed: [])

      decision = described_class.resolve(run: prepare_run)

      expect(decision).not_to be_blocked
      expect(worker_detail(decision, "compute-broken")).to include("eligible" => false)
      expect(worker_detail(decision, "compute-healthy")).to include("eligible" => true)
    end

    it "is blocked when every worker that could take it fails the check" do
      live_worker("compute-a", queues: "runs", capabilities: linux, failed: [ "mysql_client" ])
      live_worker("compute-b", queues: "runs", capabilities: linux, failed: %w[gh mysql_client])

      decision = described_class.resolve(run: prepare_run)

      expect(decision.blocked_reason).to eq("worker_environment_check_failed")
    end
  end

  describe ".locally_satisfied?" do
    let(:run) { prepare_run }

    before { repository.update!(worker_environment_requirements: %w[mysql_client]) }

    def local_snapshot(failed)
      {
        capabilities: { "os" => [ "linux" ], "arch" => [ "x86_64" ] },
        diagnostics: { "environment_smoke" => { "failed" => failed, "checks" => {} } }
      }
    end

    # RunJob hands the Run back to the queue instead of starting it here.
    it "is false when this worker failed a check the Run needs" do
      allow(WorkerCapabilities).to receive(:current).and_return(local_snapshot([ "mysql_client" ]))

      expect(described_class.locally_satisfied?(run: run)).to be(false)
    end

    it "is true when this worker's failures are checks the Run does not need" do
      allow(WorkerCapabilities).to receive(:current).and_return(local_snapshot([ "gh" ]))

      expect(described_class.locally_satisfied?(run: run)).to be(true)
    end
  end
end
