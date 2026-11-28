require "rails_helper"

# A worker that lacks a system library, header or executable the repository's
# setup needs is a worker defect, not a failure of the change. These specs pin
# the reactive half: the failure records a WorkerEnvironmentGap, placement
# avoids that worker for the repository's dependency-install work, the step is
# retried in place (the Workflow never fails), and with no provisioned worker
# left the retry holds with a named reason instead of running again.
RSpec.describe "worker environment gaps" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:prepare_step) { workflow.first_step.tap { |step| step.update!(kind: "prepare") } }
  let(:run) { prepare_step.runs.first || prepare_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:repository_id) { job.repository_id }

  def gap!(hostname:, repository_id: job.repository_id, **attrs)
    WorkerEnvironmentGap.record!(hostname: hostname, repository_id: repository_id, missing_kind: "library",
                                 missing_name: "zstd", source: "failure", **attrs)
  end

  def live_worker!(hostname, started_at: 1.hour.ago)
    InstanceVersion.create!(hostname: hostname, role: "worker", version: "test", started_at: started_at,
                            last_heartbeat_at: Time.current)
  end

  describe WorkerEnvironmentGap do
    it "blocks only the repository it was found for" do
      gap!(hostname: "worker-a")

      expect(described_class.blocks?(hostname: "worker-a", repository_id: repository_id)).to be(true)
      expect(described_class.blocks?(hostname: "worker-a", repository_id: repository_id + 1)).to be(false)
      expect(described_class.blocks?(hostname: "worker-b", repository_id: repository_id)).to be(false)
    end

    it "treats a repository-less (probe) gap as blocking every repository" do
      described_class.record!(hostname: "worker-a", missing_kind: "executable", missing_name: "gh", source: "probe")

      expect(described_class.blocks?(hostname: "worker-a", repository_id: repository_id)).to be(true)
    end

    it "stops blocking once it expires, is cleared, or the worker restarted after it" do
      expired = gap!(hostname: "worker-expired")
      expired.update!(expires_at: 1.minute.ago)
      gap!(hostname: "worker-cleared")
      described_class.clear!(hostname: "worker-cleared", repository_id: repository_id)
      gap!(hostname: "worker-restarted", now: 2.hours.ago)
      live_worker!("worker-restarted", started_at: 10.minutes.ago)

      %w[worker-expired worker-cleared worker-restarted].each do |hostname|
        expect(described_class.blocks?(hostname: hostname, repository_id: repository_id)).to be(false), hostname
      end
    end

    it "refreshes one row instead of piling up duplicates" do
      first = gap!(hostname: "worker-a")
      second = gap!(hostname: "worker-a")

      expect(second.id).to eq(first.id)
      expect(described_class.count).to eq(1)
    end
  end

  describe RunQueueResolver do
    before do
      live_worker!("worker-unprovisioned")
      live_worker!("worker-provisioned")
    end

    it "does not pin the repository's prepare back onto the gapped worker it last ran on" do
      workflow.update_columns(worker_hostname: "worker-unprovisioned", worker_storage_key: nil)
      expect(described_class.resolve(run: run)).to have_attributes(sticky_resume: true)

      gap!(hostname: "worker-unprovisioned")
      decision = described_class.resolve(run: run)

      expect(decision).not_to be_blocked
      expect(decision.sticky_resume).to be(false)
      expect(decision.queue_name).not_to eq(Workflow.resume_queue_name("worker-unprovisioned"))
      expect(decision.details["worker_environment_gaps"]).to include(include("hostname" => "worker-unprovisioned", "missing_name" => "zstd"))
      expect(described_class.worker_environment_blocks?(run: run, hostname: "worker-unprovisioned")).to be(true)
    end

    it "blocks with a named reason when every live worker lacks the dependency" do
      gap!(hostname: "worker-unprovisioned")
      gap!(hostname: "worker-provisioned")

      decision = described_class.resolve(run: run)

      expect(decision.blocked_reason).to eq("worker_environment_missing")
    end

    it "does not hold work that installs nothing" do
      gap!(hostname: "worker-unprovisioned")
      gap!(hostname: "worker-provisioned")
      prepare_step.update!(kind: "pr_open")

      expect(described_class.resolve(run: run)).not_to be_blocked
    end

    it "hands a Run back from the local worker when it is the gapped one" do
      gap!(hostname: SyrusVersion.hostname)

      expect(described_class.locally_satisfied?(run: run)).to be(false)
    end
  end

  describe "a prepare Run that failed for a missing worker dependency" do
    def fail_with_missing_zstd!(hostname: "worker-unprovisioned")
      workflow.update_columns(state: "running", worker_hostname: hostname, worker_storage_key: "storage-#{hostname}")
      prepare_step.update_columns(state: "running")
      run.update_columns(state: "running", started_at: 1.minute.ago)
      SpawnedProcess.create!(run: run, workflow: workflow, kind: "prepare", command: "bundle install",
                             hostname: hostname, started_at: 1.minute.ago, finished_at: Time.current, outcome: "failed")
      RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed",
                            error_message: "prepare command failed (exit 5): bundle install",
                            problem_code: "worker_environment_missing",
                            problem_evidence: { "missing_kind" => "library", "missing_name" => "zstd" })
      run.reload.fail!
      run.save!
    end

    it "records the gap against the worker it failed on and retries the step in place" do
      fail_with_missing_zstd!

      gap = WorkerEnvironmentGap.sole
      expect(gap).to have_attributes(hostname: "worker-unprovisioned", repository_id: repository_id,
                                     missing_kind: "library", missing_name: "zstd", source: "failure", run_id: run.id)
      expect(prepare_step.reload).not_to be_failed
      expect(workflow.reload).not_to be_failed
      expect(AutoRetryAttempt.pending.sole).to have_attributes(
        failure_classification: "worker_environment_missing", retry_kind: "failed_step"
      )
    end

    it "moves the retry off the unprovisioned worker" do
      fail_with_missing_zstd!
      attempt = AutoRetryAttempt.pending.sole

      AutoRetryJob.perform_now(attempt.id)

      expect(workflow.reload).to have_attributes(worker_hostname: nil, worker_storage_key: nil,
                                                 last_workspace_hostname: "worker-unprovisioned")
      expect(prepare_step.runs.where(state: "queued").count).to eq(1)
    end

    it "clears the gap when the same repository's prepare later succeeds on that worker" do
      gap!(hostname: "worker-unprovisioned")
      workflow.update_columns(state: "running")
      prepare_step.update_columns(state: "running")
      run.update_columns(state: "running", started_at: 1.minute.ago)
      SpawnedProcess.create!(run: run, workflow: workflow, kind: "prepare", command: "bundle install",
                             hostname: "worker-unprovisioned", started_at: 1.minute.ago, finished_at: Time.current,
                             outcome: "succeeded")

      run.reload.succeed!
      run.save!

      expect(WorkerEnvironmentGap.blocks?(hostname: "worker-unprovisioned", repository_id: repository_id)).to be(false)
    end
  end

  it "counts as infrastructure in grader collect, never as the change's verdict" do
    expect(Steps::GraderCollect::INFRASTRUCTURE_FAILURE_CLASSIFICATIONS).to include("worker_environment_missing")
  end
end
