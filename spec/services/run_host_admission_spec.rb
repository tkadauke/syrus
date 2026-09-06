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

  # `grader` and `preflight_grader` used to be guarded on sight alongside
  # agentic steps. With one slot per host that made admission a strict mutex:
  # one grader excluded every agent AND every other grader on the pod, and
  # production ran three compute tasks across three pods with capacity spare.
  # Graders are judged by predicted cost now.
  describe "graders are admitted on cost, not on being graders" do
    CHEAP = { cpu_pressure: 1.0, process_attributed_cpu_percent: 1.0, duration_seconds: 10 }.freeze

    def grader_run(kind: "grader")
      step = Step.create!(workflow: workflow, kind: kind, position: rand(100..999))
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    it "no longer guards grader kinds on sight" do
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).not_to include("grader", "preflight_grader")
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).to include("implement")
    end

    it "admits a cheap grader while another cheap grader is running" do
      worker_sample(cpu_pressure_some: 1.0)
      allow_any_instance_of(described_class).to receive(:prediction_for).and_return(CHEAP)
      running = grader_run
      running.start!
      running.save!

      decision = described_class.call(run: grader_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("resource_guard_not_needed")
    end

    # No profile yet predicts conservatively, which is expensive by
    # construction, so a brand-new grader still takes a slot until it has been
    # observed. That is the safe direction for an unknown cost.
    it "still guards a grader whose cost is unknown" do
      worker_sample(cpu_pressure_some: 1.0)
      running = grader_run
      running.start!
      running.save!

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
    end

    it "still lets an agentic run hold the host slot against a cheap grader" do
      worker_sample(cpu_pressure_some: 1.0)
      allow_any_instance_of(described_class).to receive(:prediction_for).and_return(CHEAP)
      agentic = Step.create!(workflow: workflow, kind: "implement", position: 60)
        .runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      agentic.start!
      agentic.save!

      decision = described_class.call(run: grader_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("resource_guard_not_needed")
    end
  end
end
