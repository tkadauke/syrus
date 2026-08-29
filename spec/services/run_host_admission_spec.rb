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
end
