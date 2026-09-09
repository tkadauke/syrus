require "rails_helper"

RSpec.describe RunHostAdmission do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) { workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }

  before do
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-a")
    workflow.update!(worker_hostname: "worker-a", worker_storage_key: "storage-a")
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

  it "defers sticky resume work on a pressured host" do
    worker_sample(io_pressure_some: 55.0)

    decision = described_class.call(run: run, queue_name: "resume-storage-a")

    expect(decision).to be_defer
    expect(decision.reason).to eq("local_worker_pressure_critical")
    expect(decision.details).to include(
      "queue_name" => "resume-storage-a",
      "sticky_resume_queue" => true
    )
  end

  it "defers agentic landing work on the merges queue when the selected host is critical" do
    landing_workflow = Workflows::AutoMerge.instantiate(job: job, agent_provider: "codex")
    landing_workflow.update!(worker_hostname: "worker-a")
    landing_step = landing_workflow.steps.create!(kind: "landing_fix", position: 99)
    landing_run = landing_step.runs.create!(
      job: job,
      trigger_kind: landing_workflow.trigger_kind,
      agent_provider: landing_workflow.agent_provider
    )
    worker_sample(cpu_pressure_some: 55.0)

    decision = described_class.call(run: landing_run, queue_name: "merges")

    expect(decision).to be_defer
    expect(decision.reason).to eq("local_worker_pressure_critical")
    expect(decision.details).to include(
      "queue_name" => "merges",
      "step_kind" => "landing_fix",
      "sticky_resume_queue" => false
    )
  end

  it "keeps a further workflow step off a worker storage slot that is already active" do
    worker_sample(cpu_pressure_some: 1.0)
    active_slot_run!
    workflow.update!(state: "running")

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("worker_step_slot_busy")
    expect(decision.details).to include(
      "active_slot_run_count" => RunHostAdmission::GUARDED_RUNS_PER_SLOT,
      "guarded_runs_per_slot" => RunHostAdmission::GUARDED_RUNS_PER_SLOT,
      "worker_storage_key" => "storage-a",
      "slot_key" => "storage-a",
      "slot_key_source" => "worker_storage_key"
    )
  end

  it "admits a workflow step once the prior slot holder reaches a terminal state" do
    worker_sample(cpu_pressure_some: 1.0)
    active_run = active_slot_run!
    active_run.update!(state: "succeeded", finished_at: Time.current)
    workflow.update!(state: "running")

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("worker_step_slot_available")
    expect(WorkflowStepWorkerSlot.active.find_by(run: run)).to have_attributes(
      slot_key: "storage-a",
      worker_hostname: "worker-a"
    )
  end

  it "uses hostname as the slot key when no durable storage key is available" do
    allow(WorkerStorageIdentity).to receive(:queue_key).and_return(nil)
    workflow.update!(worker_storage_key: nil)
    worker_sample(cpu_pressure_some: 1.0)
    active_slot_run!(worker_storage_key: nil)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.details).to include(
      "slot_key" => "worker-a",
      "slot_key_source" => "hostname"
    )
  end

  it "ignores active runs on a different worker storage slot" do
    worker_sample(cpu_pressure_some: 1.0)
    active_slot_run!(worker_storage_key: "storage-b", worker_hostname: "worker-b")
    workflow.update!(state: "running")

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("worker_step_slot_available")
  end

  it "admits when admission control is disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
    worker_sample(cpu_pressure_some: 1.0)
    active_slot_run!
    workflow.update!(state: "running")

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("admission_control_disabled")
  end

  it "never loads resource profiles" do
    worker_sample(cpu_pressure_some: 1.0)
    active_slot_run!
    workflow.update!(state: "running")

    expect(WorkflowStepResourceProfile).not_to receive(:where)

    expect(described_class.call(run: run)).to be_defer
  end

  it "admits work when the worker slot has no critical pressure or active run" do
    worker_sample(cpu_pressure_some: 10.0)
    workflow.update!(state: "running")

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("worker_step_slot_available")
  end

  def active_slot_run!(worker_storage_key: "storage-a", worker_hostname: "worker-a", step_kind: "prepare")
    @active_slot_issue_number ||= 500
    @active_slot_issue_number += 1
    other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: @active_slot_issue_number)
    other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
    other_workflow.update!(state: "running", worker_hostname: worker_hostname, worker_storage_key: worker_storage_key)
    other_step = other_workflow.steps.find_by!(kind: step_kind) || other_workflow.steps.create!(kind: step_kind, position: 99)
    other_step.update!(state: "running")
    other_run = other_step.runs.create!(
      job: other, trigger_kind: other_workflow.trigger_kind,
      agent_provider: other_workflow.agent_provider,
      state: "running", started_at: 5.minutes.ago
    )
    WorkflowStepWorkerSlot.acquire!(run: other_run, hostname: worker_hostname, storage_key: worker_storage_key)
    other_run
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

  describe "rationing applies to every workflow step" do
    def grader_run(kind: "grader")
      step = Step.create!(workflow: workflow, kind: kind, position: rand(100..999))
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    it "defers a grader on a healthy host when another workflow step owns the slot" do
      worker_sample(cpu_pressure_some: 1.0)
      active_slot_run!(step_kind: "implement")

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("worker_step_slot_busy")
    end

    it "defers mergeability_preflight on a healthy host when another workflow step owns the slot" do
      worker_sample(cpu_pressure_some: 1.0)
      active_slot_run!(step_kind: "prepare")

      decision = described_class.call(run: grader_run(kind: "mergeability_preflight"), queue_name: "merges")

      expect(decision).to be_defer
      expect(decision.reason).to eq("worker_step_slot_busy")
    end

    it "defers a grader when the host itself is in trouble" do
      worker_sample(cpu_pressure_some: 55.0)

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("local_worker_pressure_critical")
    end
  end

end
