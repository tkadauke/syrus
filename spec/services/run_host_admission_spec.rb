require "rails_helper"

RSpec.describe RunHostAdmission do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) { workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }

  before do
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    workflow.update!(worker_hostname: "worker-a")
  end

  it "defers compute runs on a worker with critical local pressure" do
    worker_sample(cpu_pressure_some: 55.0)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("local_worker_pressure_critical")
    expect(decision.details).to include(
      "hostname" => "worker-a",
      "step_kind" => "prepare"
    )
    expect(decision.details.fetch("sample_health")).to include("level" => "critical")
  end

  it "admits sticky resume work on a pressured host when no guarded run is active" do
    worker_sample(io_pressure_some: 55.0)

    decision = described_class.call(run: run, queue_name: "resume-storage-a")

    expect(decision).to be_admit
    expect(decision.reason).to eq("host_capacity_available")
    expect(decision.details).to include(
      "queue_name" => "resume-storage-a",
      "sticky_resume_queue" => true
    )
  end

  it "defers sticky resume work after the same worker died under critical pressure" do
    worker_sample(memory_used_percent: 96.0)
    workflow.update!(trigger_kind: "auto_merge")
    landing_fix = workflow.steps.create!(kind: "landing_fix", position: 99, state: "queued")
    failed = landing_fix.runs.create!(
      job: job,
      trigger_kind: "auto_merge",
      agent_provider: "codex",
      state: "failed",
      agent_outcome: "worker_died",
      started_at: 3.minutes.ago,
      finished_at: 2.minutes.ago
    )
    failed.create_run_failure_classification!(
      classification: "worker_died",
      retryable: true,
      classified_at: 2.minutes.ago
    )
    create_resource_summary!(
      failed,
      hostname: "worker-a",
      host_pressure_level: "critical",
      host_pressure_reasons: [ "memory 96.0% >= 95%" ],
      started_at: 3.minutes.ago,
      finished_at: 2.minutes.ago
    )
    retry_run = landing_fix.runs.create!(
      job: job,
      trigger_kind: "auto_merge",
      agent_provider: "codex",
      state: "queued"
    )

    decision = described_class.call(run: retry_run, queue_name: "resume-storage-a")

    expect(decision).to be_defer
    expect(decision.reason).to eq("failed_worker_host_still_critical")
    expect(decision.details).to include(
      "hostname" => "worker-a",
      "sticky_resume_queue" => true
    )
    expect(decision.details.fetch("failed_worker_retry")).to include(
      "source" => "prior_step_run",
      "source_run_id" => failed.id,
      "failed_hostname" => "worker-a",
      "failed_host_pressure_level" => "critical"
    )
  end

  it "defers auto-merge landing repair on a critical merges worker" do
    worker_sample(cpu_pressure_some: 55.0)
    workflow.update!(trigger_kind: "auto_merge")
    landing_fix = workflow.steps.create!(kind: "landing_fix", position: 99, state: "queued")
    retry_run = landing_fix.runs.create!(
      job: job,
      trigger_kind: "auto_merge",
      agent_provider: "codex",
      state: "queued"
    )

    decision = described_class.call(run: retry_run, queue_name: "merges")

    expect(decision).to be_defer
    expect(decision.reason).to eq("local_worker_pressure_critical")
  end

  it "uses retry-workflow attempt host context from the workflow artifact" do
    worker_sample(io_pressure_some: 55.0)
    source_workflow = workflow
    source_workflow.update!(trigger_kind: "auto_merge", state: "failed", finished_at: 1.minute.ago)
    source_run = run
    source_run.update!(state: "failed", agent_outcome: "worker_died", finished_at: 1.minute.ago)
    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: source_workflow,
      run: source_run,
      agent_provider: "codex",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: Time.current,
      failed_hostname: "worker-a",
      failed_host_pressure_level: "critical",
      failed_host_pressure_started_at: 3.minutes.ago,
      failed_host_pressure_finished_at: 1.minute.ago,
      failed_host_pressure_sample_count: 5,
      failed_host_pressure_reasons: [ "IO pressure 55.0% >= 50%" ]
    )
    retry_workflow = Workflows::AutoMerge.instantiate(
      job: job,
      agent_provider: "codex",
      artifacts: { "auto_retry_attempt_id" => attempt.id }
    )
    retry_workflow.update!(worker_hostname: "worker-a")
    landing_fix = retry_workflow.steps.create!(kind: "landing_fix", position: 99, state: "queued")
    retry_run = landing_fix.runs.create!(
      job: job,
      trigger_kind: "auto_merge",
      agent_provider: "codex",
      state: "queued"
    )

    decision = described_class.call(run: retry_run, queue_name: "resume-storage-a")

    expect(decision).to be_defer
    expect(decision.reason).to eq("failed_worker_host_still_critical")
    expect(decision.details.fetch("failed_worker_retry")).to include(
      "source" => "auto_retry_attempt",
      "auto_retry_attempt_id" => attempt.id,
      "failed_hostname" => "worker-a"
    )
  end

  it "keeps a second guarded run off a host that already has guarded compute work" do
    active_job = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 43)
    active_workflow = Workflows::Initial.instantiate(job: active_job, agent_provider: "codex")
    active_workflow.update!(state: "running", worker_hostname: "worker-a")
    active_step = active_workflow.steps.find_by!(kind: "implement")
    active_step.update!(state: "running")
    active_step.runs.create!(
      job: active_job,
      trigger_kind: active_workflow.trigger_kind,
      agent_provider: active_workflow.agent_provider,
      state: "running",
      started_at: 5.minutes.ago
    )
    workflow.update!(state: "running")
    implement_step = workflow.steps.find_by!(kind: "implement")
    run.update!(step: implement_step)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("host_resource_semaphore_busy")
    expect(decision.details).to include("active_guarded_run_count" => 1)
  end

  it "does not load resource profiles when an active run is obviously guarded by step kind" do
    active_job = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 44)
    active_workflow = Workflows::Initial.instantiate(job: active_job, agent_provider: "codex")
    active_workflow.update!(state: "running", worker_hostname: "worker-a")
    active_step = active_workflow.steps.find_by!(kind: "implement")
    active_step.update!(state: "running")
    active_step.runs.create!(
      job: active_job,
      trigger_kind: active_workflow.trigger_kind,
      agent_provider: active_workflow.agent_provider,
      state: "running",
      started_at: 5.minutes.ago
    )
    workflow.update!(state: "running")
    implement_step = workflow.steps.find_by!(kind: "implement")
    run.update!(step: implement_step)

    expect(WorkflowStepResourceProfile).not_to receive(:where)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("host_resource_semaphore_busy")
  end

  it "admits guarded work when the host has no critical pressure or active guarded run" do
    worker_sample(cpu_pressure_some: 10.0)
    low_cost_profile(step_kind: "prepare")

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("host_capacity_available")
  end

  def worker_sample(**attrs)
    WorkerHostHealthSample.create!({
      hostname: "worker-a",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      raw_metrics: {}
    }.merge(attrs))
  end

  def low_cost_profile(step_kind:)
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: workflow.agent_provider,
      trigger_kind: workflow.trigger_kind,
      step_kind: step_kind,
      grader_name: "",
      job_kind: job.kind.to_s,
      sample_count: 30,
      attributed_sample_count: 30,
      process_attributed_sample_count: 30,
      host_pressure_sample_count: 30,
      attribution_quality: "process_attributed",
      p90_duration_seconds: 10,
      p90_cpu_pressure: 1.0,
      p90_io_pressure: 1.0,
      p90_memory_used_percent: 10.0,
      p90_process_attributed_duration_seconds: 10,
      p90_process_attributed_cpu_percent: 1.0,
      p90_process_attributed_memory_bytes: 10.megabytes,
      p90_process_attributed_io_bytes: 1.megabyte,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: Time.current,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  def create_resource_summary!(run, hostname:, host_pressure_level:, host_pressure_reasons:, started_at:, finished_at:)
    RunResourceSummary.create!(
      run: run,
      job: run.job,
      workflow: run.workflow,
      step: run.step,
      repository: run.job.repository,
      user: run.user,
      agent_provider: run.agent_provider,
      trigger_kind: run.workflow.trigger_kind,
      step_kind: run.step.kind,
      hostname: hostname,
      started_at: started_at,
      finished_at: finished_at,
      duration_seconds: finished_at - started_at,
      host_sample_count: 3,
      host_sample_confidence: "sufficient",
      host_pressure_level: host_pressure_level,
      host_pressure_reasons: host_pressure_reasons,
      process_attribution_method: "none",
      process_attribution_version: 1,
      process_attribution_confidence: "unknown",
      summary_version: RunResourceSummary::SUMMARY_VERSION
    )
  end
end
