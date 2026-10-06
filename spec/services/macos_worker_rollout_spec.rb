require "rails_helper"

RSpec.describe MacosWorkerRollout do
  let(:now) { Time.zone.parse("2026-10-03 18:30:00 UTC") }
  let(:desired_version) { { "version" => "1.2.3", "git_sha" => "newsha" } }

  def mac_worker(hostname:, version: "oldsha", observed_at: now, capabilities: { "os" => [ "macos" ] }, updater_status: {})
    InstanceVersion.create!(
      hostname: hostname,
      role: "worker",
      version: version,
      started_at: observed_at - 10.minutes,
      last_heartbeat_at: observed_at,
      capabilities: capabilities,
      capability_diagnostics: { "xcode" => true },
      macos_updater_status: updater_status,
      desired_version: desired_version
    )
  end

  def sample(hostname:, storage_key:, observed_at: now)
    WorkerHostHealthSample.create!(
      hostname: hostname,
      worker_storage_key: storage_key,
      role: "worker",
      version: "oldsha",
      observed_at: observed_at,
      cpu_used_percent: 20,
      capabilities: { "os" => [ "macos" ] }
    )
  end

  it "starts updating one idle outdated macOS worker" do
    travel_to(now) do
      mac_worker(hostname: "mac-mini-a")
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      mac_worker(hostname: "mac-mini-b", version: "newsha")
      sample(hostname: "mac-mini-b", storage_key: "storage-b")

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("updating")
      drain = MacosWorkerDrain.sole
      expect(drain).to have_attributes(
        worker_storage_key: "storage-a",
        hostname: "mac-mini-a",
        state: "updating",
        desired_git_sha: "newsha"
      )
    end
  end

  it "waits for active work to finish before requesting update" do
    travel_to(now) do
      job = Factories.job
      job.initial_run.workflow.update!(worker_storage_key: "storage-a", worker_hostname: "mac-mini-a")
      job.initial_run.update!(state: "running", started_at: now - 5.minutes)
      mac_worker(hostname: "mac-mini-a")
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "draining", drain_started_at: now - 1.minute, desired_git_sha: "newsha", desired_version: desired_version)

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("waiting_for_active_work")
      expect(result.active_run_count).to eq(1)
      expect(MacosWorkerDrain.sole.state).to eq("draining")
    end
  end

  it "requests update once the drained worker is idle" do
    travel_to(now) do
      mac_worker(hostname: "mac-mini-a")
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "draining", drain_started_at: now - 1.minute, desired_git_sha: "newsha", desired_version: desired_version)

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("updating")
      expect(MacosWorkerDrain.sole).to have_attributes(state: "updating", update_started_at: now)
    end
  end

  it "completes after a fresh desired-version heartbeat passes capability smoke checks" do
    travel_to(now) do
      mac_worker(hostname: "mac-mini-a", version: "newsha")
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "updating", drain_started_at: now - 5.minutes, update_started_at: now - 2.minutes, desired_git_sha: "newsha", desired_version: desired_version)

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("completed")
      expect(MacosWorkerDrain.sole).to have_attributes(state: "completed", completed_at: now, last_error: nil)
    end
  end

  it "fails when the updater reports failure" do
    travel_to(now) do
      mac_worker(hostname: "mac-mini-a", updater_status: { "state" => "failed", "message" => "checksum mismatch", "observed_at" => now.iso8601 })
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "updating", drain_started_at: now - 5.minutes, update_started_at: now - 1.minute, desired_git_sha: "newsha", desired_version: desired_version)

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("failed")
      expect(MacosWorkerDrain.sole).to have_attributes(state: "failed", last_error: "checksum mismatch")
    end
  end

  it "fails when the selected worker stops heartbeating" do
    travel_to(now) do
      mac_worker(hostname: "mac-mini-a", observed_at: now - 20.minutes)
      sample(hostname: "mac-mini-a", storage_key: "storage-a", observed_at: now - 20.minutes)
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "updating", drain_started_at: now - 20.minutes, update_started_at: now - 16.minutes, desired_git_sha: "newsha", desired_version: desired_version)

      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("failed")
      expect(MacosWorkerDrain.sole.last_error).to match(/heartbeat is stale/)
    end
  end

  it "allows forced termination to move an active worker into update" do
    travel_to(now) do
      job = Factories.job
      job.initial_run.workflow.update!(worker_storage_key: "storage-a", worker_hostname: "mac-mini-a")
      job.initial_run.update!(state: "running", started_at: now - 5.minutes)
      mac_worker(hostname: "mac-mini-a")
      sample(hostname: "mac-mini-a", storage_key: "storage-a")
      MacosWorkerDrain.create!(worker_storage_key: "storage-a", hostname: "mac-mini-a", state: "draining", drain_started_at: now - 1.minute, desired_git_sha: "newsha", desired_version: desired_version)

      described_class.force_terminate!(worker_storage_key: "storage-a", desired_version: desired_version, now: now)
      result = described_class.advance!(desired_version: desired_version, now: now)

      expect(result.state).to eq("updating")
      expect(MacosWorkerDrain.sole.force_terminate_at).to eq(now)
    end
  end
end
