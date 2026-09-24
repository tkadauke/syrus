require "rails_helper"

RSpec.describe RunHostAdmission do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) { workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }

  before do
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    allow(RunProcessParallelism).to receive(:host_capacity).and_return(6)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16.gigabytes)
    allow(RunProcessParallelism).to receive(:current_memory_bytes).and_return(2.gigabytes)
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
      "active_guarded_run_count" => 3
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

  # Host-correlated profile pressure remains unsuitable for admission. Only
  # command-attributed memory bytes may increase the reservation.
  it "does not let host-correlated profiles tighten admission" do
    worker_sample(cpu_pressure_some: 1.0)
    saturate_guarded_slots!
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

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

  # syrus_admission_decisions_total is the same per-process counter
  # WorkflowAdmissionBudget increments; RunHostAdmission's own admit/defer
  # decisions feed it too (see config/syrus_docs/metrics.md). Reads the count
  # before/after since the registry is real and process-global.
  it "increments syrus_admission_decisions_total for both admit and defer decisions" do
    admit_before = admission_decisions_total("admit")
    defer_before = admission_decisions_total("defer")

    worker_sample(cpu_pressure_some: 10.0)
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))
    described_class.call(run: run)

    expect(admission_decisions_total("admit")).to eq(admit_before + 1)

    worker_sample(cpu_pressure_some: 55.0)
    described_class.call(run: run)

    expect(admission_decisions_total("defer")).to eq(defer_before + 1)
  end

  it "admits control-plane steps on a worker with critical local pressure" do
    enable_distributed_workflow_dag!
    worker_sample(cpu_pressure_some: 55.0)
    landing_workflow = Workflows::MergeTrain.instantiate(job: job, agent_provider: "codex")
    landing_workflow.update!(worker_hostname: "worker-a")
    collect_step = landing_workflow.steps.find_by!(kind: "grader_collect")
    collect_run = collect_step.runs.create!(
      job: job,
      trigger_kind: landing_workflow.trigger_kind,
      agent_provider: landing_workflow.agent_provider
    )

    decision = described_class.call(run: collect_run, queue_name: "merges")

    expect(decision).to be_admit
    expect(decision.reason).to eq("control_plane_step")
    expect(decision.details).to include(
      "queue_name" => "merges",
      "step_kind" => "grader_collect"
    )
  end

  def enable_distributed_workflow_dag!
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!
    repository.update!(distributed_workflow_dag_enabled: true)
    repository.reload
    job.association(:repository).reset
  end

  # The per-host slot count is a lag backstop, not a capacity model, so a spec
  # that wants "the host is full" has to actually fill it.
  def saturate_guarded_slots!(count: 3)
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

  def admission_decisions_total(decision)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).samples.to_h[{ decision: decision }].to_i
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

  def low_cost_profile(step_kind:, grader_name: "")
    create_profile(step_kind: step_kind, grader_name: grader_name, duration: 10, cpu: 1.0)
  end

  def process_attributed_grader_profile(grader_name:, io_bytes:, memory_bytes:)
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: workflow.agent_provider,
      trigger_kind: workflow.trigger_kind,
      step_kind: "grader",
      grader_name: grader_name,
      job_kind: job.kind.to_s,
      sample_count: 30,
      attributed_sample_count: 0,
      process_attributed_sample_count: 30,
      host_pressure_sample_count: 30,
      attribution_quality: "process_attributed",
      p90_duration_seconds: 60,
      p90_cpu_pressure: 1.0,
      p90_io_pressure: 1.0,
      p90_memory_used_percent: 10.0,
      p90_process_attributed_duration_seconds: 60,
      p90_process_attributed_cpu_percent: 1.0,
      p90_process_attributed_memory_bytes: memory_bytes,
      p90_process_attributed_io_bytes: io_bytes,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: Time.current,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  def create_profile(step_kind:, grader_name:, duration:, cpu:)
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: workflow.agent_provider,
      trigger_kind: workflow.trigger_kind,
      step_kind: step_kind,
      grader_name: grader_name,
      job_kind: job.kind.to_s,
      sample_count: 30,
      attributed_sample_count: 30,
      process_attributed_sample_count: 30,
      host_pressure_sample_count: 30,
      attribution_quality: "process_attributed",
      p90_duration_seconds: duration,
      p90_cpu_pressure: cpu,
      p90_io_pressure: 1.0,
      p90_memory_used_percent: 10.0,
      p90_attributed_duration_seconds: duration,
      p90_attributed_cpu_pressure: cpu,
      p90_attributed_io_pressure: 1.0,
      p90_attributed_memory_used_percent: 10.0,
      p90_process_attributed_duration_seconds: duration,
      p90_process_attributed_cpu_percent: cpu,
      p90_process_attributed_memory_bytes: 10.megabytes,
      p90_process_attributed_io_bytes: 1.megabyte,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: Time.current,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  def running_grader_run(name:)
    other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 700 + rand(1000))
    other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
    other_workflow.update!(state: "running", worker_hostname: "worker-a")
    other_step = Step.create!(workflow: other_workflow, kind: "grader", position: rand(100..999), state: "running", details: { "name" => name })
    other_step.runs.create!(
      job: other,
      trigger_kind: other_workflow.trigger_kind,
      agent_provider: other_workflow.agent_provider,
      state: "running",
      started_at: 5.minutes.ago
    )
  end

  describe "grader rationing" do
    def grader_run(kind: "grader", name: "rspec")
      details = kind.in?(%w[grader preflight_grader]) ? { "name" => name } : {}
      step = Step.create!(workflow: workflow, kind: kind, position: rand(100..999), details: details)
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    it "guards agentic steps separately from graders" do
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).not_to include("grader", "preflight_grader")
      expect(described_class::ALWAYS_GUARDED_STEP_KINDS).to include("implement")
      worker_sample(cpu_pressure_some: 1.0)
      expect(described_class.call(run: grader_run).reason).to eq("host_capacity_available")
    end

    it "guards deterministic compute steps that can spawn memory-heavy tools" do
      worker_sample(cpu_pressure_some: 1.0)
      format_step = Step.create!(workflow: workflow, kind: "format", position: 98)
      format_run = format_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)

      decision = described_class.call(run: format_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("host_capacity_available")
    end

    it "defers compute when measured container memory leaves no room for the candidate" do
      worker_sample(cpu_pressure_some: 1.0)
      allow(RunProcessParallelism).to receive(:current_memory_bytes).and_return(13.gigabytes)

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include(
        "host_memory_limit_bytes" => 16.gigabytes,
        "current_memory_bytes" => 13.gigabytes
      )
    end

    it "uses command-attributed memory to reserve multiple host-scaled units" do
      worker_sample(cpu_pressure_some: 1.0)
      process_attributed_grader_profile(
        grader_name: "rspec",
        io_bytes: 1.megabyte,
        memory_bytes: 6.gigabytes
      )
      allow(RunProcessParallelism).to receive(:current_memory_bytes).and_return(8.gigabytes)

      decision = described_class.call(run: grader_run(name: "rspec"))

      expect(decision).to be_defer
      expect(decision.details.fetch("candidate_reserved_memory_bytes")).to eq(6.gigabytes)
    end

    it "uses the same host budget for graders and agentic runs" do
      worker_sample(cpu_pressure_some: 1.0)
      saturate_guarded_slots!

      decision = described_class.call(run: grader_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include(
        "active_compute_units" => 6,
        "candidate_compute_units" => 1,
        "host_compute_capacity" => 6
      )
    end

    it "admits a cheap grader on a warning host while grader slots remain" do
      worker_sample(cpu_pressure_some: 25.0)
      low_cost_profile(step_kind: "grader", grader_name: "rspec")

      decision = described_class.call(run: grader_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("host_capacity_available")
    end

    it "defers background main-health graders on a warning host while landing work is active" do
      worker_sample(cpu_pressure_some: 25.0)
      landing_workflow = Workflows::AutoMerge.instantiate(job: job, agent_provider: "codex")
      landing_workflow.update!(state: "running", worker_hostname: "worker-a")
      main_grader_job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "main_grader",
        state: "running",
        issue_number: nil,
        issue_title: "main_grader:abc123"
      )
      main_workflow = Workflows::MainGrader.instantiate(job: main_grader_job, agent_provider: "codex")
      main_workflow.update!(state: "running", worker_hostname: "worker-a")
      main_step = Step.create!(workflow: main_workflow, kind: "grader", position: 99, details: { "name" => "rspec" })
      main_run = main_step.runs.create!(
        job: main_grader_job,
        trigger_kind: main_workflow.trigger_kind,
        agent_provider: main_workflow.agent_provider
      )

      decision = described_class.call(run: main_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("landing_work_has_priority")
    end

    it "does not make landing graders yield to background main-health work" do
      worker_sample(cpu_pressure_some: 25.0)
      main_grader_job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "main_grader",
        state: "running",
        issue_number: nil,
        issue_title: "main_grader:abc123"
      )
      main_workflow = Workflows::MainGrader.instantiate(job: main_grader_job, agent_provider: "codex")
      main_workflow.update!(state: "running", worker_hostname: "worker-a")
      main_step = Step.create!(workflow: main_workflow, kind: "grader", position: 99, state: "running", details: { "name" => "rspec" })
      main_step.runs.create!(
        job: main_grader_job,
        trigger_kind: main_workflow.trigger_kind,
        agent_provider: main_workflow.agent_provider,
        state: "running",
        started_at: 1.minute.ago
      )
      landing_workflow = Workflows::AutoMerge.instantiate(job: job, agent_provider: "codex")
      landing_workflow.update!(state: "running", worker_hostname: "worker-a")
      landing_step = Step.create!(workflow: landing_workflow, kind: "grader", position: 99, details: { "name" => "rspec" })
      landing_run = landing_step.runs.create!(
        job: job,
        trigger_kind: landing_workflow.trigger_kind,
        agent_provider: landing_workflow.agent_provider
      )

      decision = described_class.call(run: landing_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("host_capacity_available")
    end

    it "defers the next grader when graders consume the host budget" do
      worker_sample(cpu_pressure_some: 1.0)
      6.times { running_grader_run(name: "rspec") }

      decision = described_class.call(run: grader_run(name: "rspec"))

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include(
        "resource_guard_kind" => "grader",
        "active_grader_run_count" => 6,
        "guarded_runs_per_host" => 6,
        "host_compute_capacity" => 6
      )
    end

    it "defers a second process-attributed high-IO grader on a warning host" do
      worker_sample(cpu_pressure_some: 25.0)
      process_attributed_grader_profile(
        grader_name: "rspec",
        io_bytes: 2.gigabytes,
        memory_bytes: 128.megabytes
      )
      running_grader_run(name: "rspec")

      decision = described_class.call(run: grader_run(name: "rspec"))

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include(
        "resource_guard_kind" => "io_intensive_grader",
        "active_io_intensive_grader_run_count" => 1
      )
    end

    it "counts live distributed grader processes on this host even when their workflow owner is elsewhere" do
      worker_sample(cpu_pressure_some: 25.0)
      process_attributed_grader_profile(
        grader_name: "rspec",
        io_bytes: 2.gigabytes,
        memory_bytes: 128.megabytes
      )
      active_run = running_grader_run(name: "rspec")
      active_run.workflow.update!(worker_hostname: "worker-b")
      active_run.spawned_processes.create!(
        workflow: active_run.workflow,
        kind: "grader",
        command: "bin/rspec",
        hostname: "worker-a",
        started_at: 1.minute.ago
      )

      decision = described_class.call(run: grader_run(name: "rspec"))

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include("active_io_intensive_grader_run_count" => 1)
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

  # visual_diff previews spawn a headless browser against a preview app on top
  # of the agent turn itself, so colocating more than one on an already-loaded
  # host is exactly the kind of burst that produced critical IO pressure in
  # the 2026-09-14 incident batches.
  describe "visual_diff preview colocation" do
    def visual_diff_run(job_for_run: job)
      visual_diff_workflow = Workflows::VisualDiff.instantiate(job: job_for_run, agent_provider: "codex")
      visual_diff_workflow.update!(state: "running", worker_hostname: "worker-a")
      visual_diff_step = visual_diff_workflow.steps.find_by!(kind: "visual_diff")
      visual_diff_step.update!(state: "running")
      visual_diff_step.runs.create!(
        job: job_for_run,
        trigger_kind: visual_diff_workflow.trigger_kind,
        agent_provider: visual_diff_workflow.agent_provider
      )
    end

    def other_running_visual_diff_preview!
      other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 800 + rand(1000))
      run = visual_diff_run(job_for_run: other)
      run.update!(state: "running", started_at: 5.minutes.ago)
      run
    end

    it "defers a second colocated visual_diff preview on a warning host" do
      worker_sample(cpu_pressure_some: 25.0)
      other_running_visual_diff_preview!

      decision = described_class.call(run: visual_diff_run)

      expect(decision).to be_defer
      expect(decision.reason).to eq("host_resource_semaphore_busy")
      expect(decision.details).to include(
        "resource_guard_kind" => "visual_diff_preview",
        "active_visual_diff_preview_run_count" => 1,
        "guarded_runs_per_host" => 1
      )
    end

    it "admits a lone visual_diff preview on a warning host" do
      worker_sample(cpu_pressure_some: 25.0)

      decision = described_class.call(run: visual_diff_run)

      expect(decision).to be_admit
      expect(decision.reason).to eq("host_capacity_available")
    end

    it "admits a second colocated visual_diff preview on a healthy host" do
      worker_sample(cpu_pressure_some: 1.0)
      other_running_visual_diff_preview!

      decision = described_class.call(run: visual_diff_run)

      expect(decision).to be_admit
    end

    it "still defers visual_diff work outright when the host is under critical pressure" do
      worker_sample(cpu_pressure_some: 55.0)

      decision = described_class.call(run: visual_diff_run)

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
