require "rails_helper"

# A worker that lacks a system library, header or executable the repository's
# setup needs is a worker defect, not a failure of the change. These specs pin
# the reactive half of the one placement model: the failure records a
# WorkerEnvironmentGap, which RunQueueResolver reads as a failed environment
# check -- the same view, and the same hold reason, as a failed smoke check
# (WorkerEnvironmentSmoke) -- the step is retried in place, and a passing
# smoke report for the same check clears it.
RSpec.describe "worker environment gaps" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:prepare_step) { workflow.first_step.tap { |step| step.update!(kind: "prepare") } }
  let(:run) { prepare_step.runs.first || prepare_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:repository_id) { job.repository_id }

  def gap!(hostname:, repository_id: job.repository_id, missing_name: "zstd", **attrs)
    WorkerEnvironmentGap.record!(hostname: hostname, repository_id: repository_id, missing_kind: "library",
                                 missing_name: missing_name, **attrs)
  end

  def live_worker!(hostname, started_at: 1.hour.ago, smoke: nil)
    diagnostics = smoke ? { WorkerEnvironmentSmoke::DIAGNOSTIC_KEY => smoke } : {}
    InstanceVersion.create!(hostname: hostname, role: "worker", version: "test", started_at: started_at,
                            last_heartbeat_at: Time.current, capability_diagnostics: diagnostics)
  end

  def passing_report(check, observed_at: Time.current)
    { "version" => 1, "status" => "passed", "observed_at" => observed_at.utc.iso8601(6), "failed" => [],
      "checks" => { check => { "status" => "passed" } } }
  end

  describe WorkerEnvironmentGap do
    it "names the smoke check that covers the same thing, so a probe and a failure agree" do
      expect(gap!(hostname: "w", missing_name: "zstd").check_name).to eq("mysql_client")
      expect(described_class.record!(hostname: "w", repository_id: repository_id, missing_kind: "executable",
                                     missing_name: "gh").check_name).to eq("gh")
      expect(described_class.record!(hostname: "w", repository_id: repository_id, missing_kind: "executable",
                                     missing_name: "playwright-mcp").check_name).to eq("missing_executable:playwright-mcp")
    end

    it "keeps a worker off only the repository whose install found the gap" do
      gap!(hostname: "worker-a")

      expect(described_class.failed_checks(hostname: "worker-a", repository_id: repository_id)).to have_key("mysql_client")
      expect(described_class.failed_checks(hostname: "worker-a", repository_id: repository_id + 1)).to eq({})
      expect(described_class.failed_checks(hostname: "worker-b", repository_id: repository_id)).to eq({})
    end

    # A gap found preparing one grader target (xcodegen for an iOS target) once
    # kept a macOS worker off every step of the repository, so a landing train
    # that never runs that target failed with no capable worker.
    it "holds only work that runs the target whose prepare found the gap" do
      described_class.record!(hostname: "mac", repository_id: repository_id, missing_kind: "executable",
                              missing_name: "xcodegen", evidence: { "prepare_target" => "//ios:prepare" })

      expect(described_class.failed_checks(hostname: "mac", repository_id: repository_id)).to eq({})
      expect(described_class.failed_checks(hostname: "mac", repository_id: repository_id, prepare_targets: [ "//web:prepare" ])).to eq({})
      expect(described_class.failed_checks(hostname: "mac", repository_id: repository_id, prepare_targets: [ "//ios:prepare" ]))
        .to have_key("missing_executable:xcodegen")
    end

    it "keeps the prepare target a failed target install declared" do
      run.update!(state: "failed")
      run.spawned_processes.create!(workflow: workflow, kind: "prepare", command: "xcodegen generate", hostname: "mac", started_at: Time.current)

      gap = described_class.record_from_run!(run, problem_evidence: {
        "missing_kind" => "executable", "missing_name" => "xcodegen", "prepare_target" => "//ios:prepare"
      })

      expect(gap.prepare_target).to eq("//ios:prepare")
    end

    it "stops counting once it expires, is cleared, or the worker restarted after it" do
      gap!(hostname: "worker-expired").update!(expires_at: 1.minute.ago)
      gap!(hostname: "worker-cleared")
      described_class.clear!(hostname: "worker-cleared", repository_id: repository_id)
      gap!(hostname: "worker-restarted", now: 2.hours.ago)
      live_worker!("worker-restarted", started_at: 10.minutes.ago)

      %w[worker-expired worker-cleared worker-restarted].each do |hostname|
        expect(described_class.failed_checks(hostname: hostname, repository_id: repository_id)).to eq({}), hostname
      end
    end

    it "stops counting once the worker's own smoke report passes the same check after the gap" do
      gap = gap!(hostname: "worker-a")

      expect(described_class.failed_checks(hostname: "worker-a", repository_id: repository_id,
                                           smoke_report: passing_report("mysql_client", observed_at: gap.detected_at - 1.minute))).not_to be_empty
      expect(described_class.failed_checks(hostname: "worker-a", repository_id: repository_id,
                                           smoke_report: passing_report("mysql_client", observed_at: 1.minute.from_now))).to eq({})
    end

    it "refreshes one row instead of piling up duplicates" do
      first = gap!(hostname: "worker-a")

      expect(gap!(hostname: "worker-a").id).to eq(first.id)
      expect(described_class.count).to eq(1)
    end
  end

  describe RunQueueResolver do
    before do
      live_worker!("worker-unprovisioned")
      live_worker!("worker-provisioned")
    end

    it "reports a failure-found gap as the worker's failed environment check" do
      gap!(hostname: "worker-unprovisioned")

      decision = described_class.resolve(run: run)
      failures = decision.details["live_workers"].to_h { |worker| [ worker["hostname"], worker["environment_check_failures"] ] }

      expect(decision).not_to be_blocked
      expect(failures["worker-unprovisioned"]).to include("mysql_client" => include("install failed on this worker"))
      expect(failures["worker-provisioned"]).to be_nil
      expect(described_class.worker_environment_blocks?(run: run, hostname: "worker-unprovisioned")).to be(true)
      expect(described_class.worker_environment_blocks?(run: run, hostname: "worker-provisioned")).to be(false)
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

      expect(WorkerEnvironmentGap.sole).to have_attributes(hostname: "worker-unprovisioned", repository_id: repository_id,
                                                           missing_kind: "library", missing_name: "zstd", run_id: run.id)
      expect(prepare_step.reload).not_to be_failed
      expect(workflow.reload).not_to be_failed
      expect(AutoRetryAttempt.pending.sole).to have_attributes(
        failure_classification: "worker_environment_missing", retry_kind: "failed_step"
      )
    end

    it "records prepare's own smoke-check refusal under the smoke check's name" do
      workflow.update_columns(state: "running", worker_hostname: "worker-unprovisioned")
      WorkerEnvironmentGap.record_from_run!(run, problem_evidence: { "failed_checks" => [ "mysql_client" ] })

      expect(WorkerEnvironmentGap.sole.check_name).to eq("mysql_client")
    end

    it "moves the retry off the unprovisioned worker" do
      fail_with_missing_zstd!

      AutoRetryJob.perform_now(AutoRetryAttempt.pending.sole.id)

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

      expect(WorkerEnvironmentGap.failed_checks(hostname: "worker-unprovisioned", repository_id: repository_id)).to eq({})
    end

    # The repository's prepare never runs a grader target's tool, so its
    # success once cleared an iOS-target gap while xcodegen was still missing.
    it "keeps a target gap when only the repository's prepare succeeds, and clears it when that target's grader does" do
      WorkerEnvironmentGap.record!(hostname: "mac", repository_id: repository_id, missing_kind: "executable",
                                   missing_name: "xcodegen", evidence: { "prepare_target" => "//ios:prepare" })
      workflow.update_columns(state: "running")
      prepare_step.update_columns(state: "running")
      run.update_columns(state: "running", started_at: 1.minute.ago)
      SpawnedProcess.create!(run: run, workflow: workflow, kind: "prepare", command: "bundle install",
                             hostname: "mac", started_at: 1.minute.ago, finished_at: Time.current, outcome: "succeeded")

      run.reload.succeed!
      run.save!

      expect(WorkerEnvironmentGap.failed_checks(hostname: "mac", repository_id: repository_id, prepare_targets: [ "//ios:prepare" ]))
        .to have_key("missing_executable:xcodegen")

      grader = workflow.steps.create!(kind: "grader", position: 50, state: "running", started_at: 1.minute.ago,
                                      details: { "name" => "ios-test", "prepare_targets" => [ { "target_label" => "//ios:prepare" } ] })
      grader_run = grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", started_at: 1.minute.ago)
      SpawnedProcess.create!(run: grader_run, workflow: workflow, kind: "grader", command: "make test",
                             hostname: "mac", started_at: 1.minute.ago, finished_at: Time.current, outcome: "succeeded")

      grader_run.reload.succeed!
      grader_run.save!

      expect(WorkerEnvironmentGap.failed_checks(hostname: "mac", repository_id: repository_id, prepare_targets: [ "//ios:prepare" ])).to eq({})
    end
  end

  it "counts as infrastructure in grader collect, never as the change's verdict" do
    expect(Steps::GraderCollect::INFRASTRUCTURE_FAILURE_CLASSIFICATIONS).to include("worker_environment_missing")
  end
end
