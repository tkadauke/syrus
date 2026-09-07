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

  it "keeps a further guarded run off a host whose slots are full" do
    worker_sample(cpu_pressure_some: 1.0)
    saturate_guarded_slots!
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("host_resource_semaphore_busy")
    expect(decision.details).to include(
      "active_guarded_run_count" => RunHostAdmission::GUARDED_RUNS_PER_HOST
    )
  end

  # The slot count is a backstop for measurement lag, not the throttle it used
  # to be at 1 -- a single agent on a healthy host no longer excludes the pod.
  it "admits a second guarded run while the host still has slots" do
    worker_sample(cpu_pressure_some: 1.0)
    saturate_guarded_slots!(count: 1)
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    decision = described_class.call(run: run)

    expect(decision).to be_admit
  end

  # Admission no longer consults resource profiles at all -- it measures the
  # host instead of predicting the step. Recorded profiles were ambient host
  # readings rather than step demand, so a 52-second API call using 2.7% CPU
  # profiled at 84 cpu_pressure and was rationed like an agent.
  it "never loads resource profiles" do
    worker_sample(cpu_pressure_some: 1.0)
    saturate_guarded_slots!
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    expect(WorkflowStepResourceProfile).not_to receive(:where)

    expect(described_class.call(run: run)).to be_defer
  end

  it "admits guarded work when the host has no critical pressure or active guarded run" do
    worker_sample(cpu_pressure_some: 10.0)
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("host_capacity_available")
  end

  # The per-host slot count is a lag backstop, not a capacity model, so a spec
  # that wants "the host is full" has to actually fill it.
  def saturate_guarded_slots!(count: RunHostAdmission::GUARDED_RUNS_PER_HOST)
    count.times do |i|
      other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 500 + i)
      other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
      other_workflow.update!(state: "running", worker_hostname: "worker-a")
      other_step = other_workflow.steps.find_by!(kind: "implement")
      other_step.update!(state: "running")
      other_step.runs.create!(
        job: other, trigger_kind: other_workflow.trigger_kind,
        agent_provider: other_workflow.agent_provider,
        state: "running", started_at: 5.minutes.ago
      )
    end
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

  # Graders used to be guarded on sight, then guarded by predicted cost. They
  # are now not rationed at all: only agentic steps take a per-host slot, and
  # everything is stopped by measured host pressure regardless of kind. The
  # cost prediction was the thing that never worked -- profiles recorded the
  # host's ambient load, not the step's demand.
  describe "rationing applies to agentic work, not to graders" do
    def grader_run(kind: "grader")
      step = Step.create!(workflow: workflow, kind: kind, position: rand(100..999))
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    it "guards agentic steps and nothing else" do
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).not_to include("grader", "preflight_grader", "mergeability_preflight")
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).to include("implement")
    end

    it "admits a grader on a healthy host regardless of what else is running" do
      worker_sample(cpu_pressure_some: 1.0)
      saturate_guarded_slots!

      decision = described_class.call(run: grader_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("resource_guard_not_needed")
    end

    # The landing step that deferred 73 times in 36 minutes on an idle fleet.
    it "admits mergeability_preflight on a healthy host" do
      worker_sample(cpu_pressure_some: 1.0)
      saturate_guarded_slots!

      decision = described_class.call(run: grader_run(kind: "mergeability_preflight"), queue_name: "merges")

      expect(decision).to be_admit
    end

    # Measured pressure still stops everything, grader or not -- that is the
    # gate that replaced the predicted budget.
    it "defers a grader when the host itself is in trouble" do
      worker_sample(cpu_pressure_some: 55.0)

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("local_worker_pressure_critical")
    end
  end

  # Host readings lag the work that produced them, so admitting several runs
  # against a single sample overshoots before the next one lands.
  describe "staggering" do
    it "defers a second admission until the sample can reflect the first" do
      worker_sample(cpu_pressure_some: 1.0)
      other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 601)
      other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
      other_workflow.update!(state: "running", worker_hostname: "worker-a")
      other_step = other_workflow.steps.find_by!(kind: "implement")
      other_step.update!(state: "running")
      other_step.runs.create!(
        job: other, trigger_kind: other_workflow.trigger_kind,
        agent_provider: other_workflow.agent_provider,
        state: "running", started_at: 2.seconds.ago
      )
      workflow.update!(state: "running")
      run.update!(step: workflow.steps.find_by!(kind: "implement"))

      decision = described_class.call(run: run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_admission_staggering")
    end

    it "admits once the stagger window has passed" do
      worker_sample(cpu_pressure_some: 1.0)
      other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 602)
      other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
      other_workflow.update!(state: "running", worker_hostname: "worker-a")
      other_step = other_workflow.steps.find_by!(kind: "implement")
      other_step.update!(state: "running")
      other_step.runs.create!(
        job: other, trigger_kind: other_workflow.trigger_kind,
        agent_provider: other_workflow.agent_provider,
        state: "running", started_at: (RunHostAdmission::STAGGER_INTERVAL + 5.seconds).ago
      )
      workflow.update!(state: "running")
      run.update!(step: workflow.steps.find_by!(kind: "implement"))

      expect(described_class.call(run: run)).to be_admit
    end
  end
end
