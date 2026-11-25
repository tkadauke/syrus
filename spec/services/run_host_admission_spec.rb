require "rails_helper"

RSpec.describe RunHostAdmission do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) { workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }
  let(:memory_psi) { { memory_pressure_some: 0.0 } }

  before do
    HostConcurrencyTarget.reset!
    AppSetting.current.update!(workflow_admission_control_enabled: true)
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    allow(RunProcessParallelism).to receive(:cpu_detection).and_return(double(count: 2, source: "cgroup"))
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16.gigabytes)
    allow(RunProcessParallelism).to receive(:current_memory_bytes).and_return(2.gigabytes)
    allow(WorkerHostHealthSampler).to receive(:memory_pressure_snapshot) { memory_psi }
    workflow.update!(worker_hostname: "worker-a")
  end

  after { HostConcurrencyTarget.reset! }

  it "admits when admission control is disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
    2.times { |i| compute_run_on_worker_a(i) }

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("admission_control_disabled")
    expect_reason_attribution(decision)
  end

  it "defers compute work on a critically pressured worker, even with admission control disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
    worker_sample(cpu_pressure_some: 55.0, cpu_pressure_full: 6.0, worker_storage_key: "storage-critical")

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("local_worker_pressure_critical")
    expect(decision.details).to include("hostname" => "worker-a", "worker_storage_key" => "storage-critical")
    expect_reason_attribution(decision)
  end

  it "does not let IO pressure alone defer a provider-bound agent turn" do
    worker_sample(io_pressure_some: 95.0, io_pressure_full: 80.0)
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    expect(described_class.call(run: run)).to be_admit
  end

  it "defers guarded work while memory is actually stalling" do
    memory_psi[:memory_pressure_some] = 12.0

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("host_resource_semaphore_busy")
    expect(decision.details["resource_guard_binding_terms"]).to eq([ "memory_pressure" ])
  end

  it "defers guarded work when measured free memory is below the floor" do
    allow(RunProcessParallelism).to receive(:current_memory_bytes).and_return(15.gigabytes)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.details).to include("resource_guard_binding_terms" => [ "memory_headroom" ], "memory_headroom_bytes" => 1.gigabyte)
  end

  # Regression: the predicted-cost allocator charged every Run an estimated
  # memory reservation and a reserve for agent turns, and refused work on a
  # worker using a fraction of its CPU and memory.
  it "admits compute work on a healthy worker below its concurrency target regardless of what the work might cost" do
    compute_run_on_worker_a(0)

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("host_capacity_available")
  end

  it "defers compute work once the worker's concurrency target is reached" do
    2.times { |i| compute_run_on_worker_a(i) }
    pin_target!(2)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.details).to include(
      "resource_guard_binding_terms" => [ "concurrency_target" ],
      "active_compute_run_count" => 2,
      "concurrency_target" => 2
    )
  end

  it "raises the target and admits once a full worker has stayed healthy" do
    2.times { |i| compute_run_on_worker_a(i) }
    pin_target!(2, adjusted_at: 1.minute.ago)

    decision = described_class.call(run: run)

    expect(decision).to be_admit
  end

  it "neither charges nor limits provider-bound agent turns by the compute target" do
    2.times { |i| compute_run_on_worker_a(i) }
    pin_target!(2)
    workflow.update!(state: "running")
    run.update!(step: workflow.steps.find_by!(kind: "implement"))

    decision = described_class.call(run: run)

    expect(decision).to be_admit
    expect(decision.reason).to eq("provider_bound_step")
  end

  it "does not count running Runs whose worker has gone quiet" do
    2.times { |i| compute_run_on_worker_a(i, heartbeat: 1.hour.ago) }
    pin_target!(2)

    expect(described_class.call(run: run)).to be_admit
  end

  it "counts a distributed grader where its process runs" do
    elsewhere = compute_run_on_worker_a(0, workflow_host: "worker-b")
    elsewhere.spawned_processes.create!(workflow: elsewhere.workflow, kind: "grader", command: "bin/rspec", hostname: "worker-a", started_at: 1.minute.ago)
    compute_run_on_worker_a(1)
    pin_target!(2)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.details["active_compute_run_count"]).to eq(2)
  end

  it "lets background work yield to landing work while the worker is under warning pressure" do
    main_grader_job = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 901)
    landing = Workflows::Initial.instantiate(job: main_grader_job, agent_provider: "codex")
    landing.update!(state: "running")
    allow(WorkDefinitions).to receive(:landing_workflow_kinds).and_return([ landing.trigger_kind ])
    allow(run).to receive(:trigger_kind).and_return("main_grader")
    worker_sample(cpu_used_percent: 6.1, load_1m: 1.8, cpu_pressure_some: 67.4, cpu_pressure_full: 0.0)

    decision = described_class.call(run: run)

    expect(decision).to be_defer
    expect(decision.reason).to eq("landing_work_has_priority")
  end

  def compute_run_on_worker_a(index, heartbeat: Time.current, workflow_host: "worker-a")
    other = Factories.job_record(user: user, repository: repository, state: "running", issue_number: 700 + index)
    other_workflow = Workflows::Initial.instantiate(job: other, agent_provider: "codex")
    other_workflow.update!(state: "running", worker_hostname: workflow_host)
    other_step = other_workflow.first_step
    other_step.update!(state: "running")
    other_step.runs.create!(
      job: other, trigger_kind: other_workflow.trigger_kind, agent_provider: other_workflow.agent_provider,
      state: "running", started_at: 2.hours.ago, last_heartbeat_at: heartbeat
    )
  end

  def pin_target!(target, adjusted_at: Time.current)
    HostConcurrencyTarget.default_path.write(JSON.generate("target" => target, "adjusted_at" => adjusted_at.iso8601))
  end

  def admission_decisions_for_reason(decision, reason)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).samples.to_h[{ decision: decision, reason: reason }].to_i
  end

  def expect_reason_attribution(decision)
    expect(decision.details["reason"]).to eq(decision.reason)
    expect(admission_decisions_for_reason(decision.action, decision.reason)).to be_positive
  end

  def worker_sample(**attrs)
    WorkerHostHealthSample.create!({
      hostname: "worker-a", role: "worker", version: "test", observed_at: Time.current, raw_metrics: {}
    }.merge(attrs))
  end
end
