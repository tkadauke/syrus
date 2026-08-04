require "rails_helper"

RSpec.describe WorkflowAdmissionBudget do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def workflow_for(priority: "medium", state: "queued", trigger_kind: "initial")
    job = Factories.job_record(user: user, repository: repository, priority: priority, state: "queued")
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "codex")
    workflow.update!(state: state)
    workflow
  end

  def profile(step_kind:, duration: 60, cpu: 5.0, io: 5.0, memory: 20.0, grader_name: "", attributed_samples: 0, attributed_duration: nil, attributed_cpu: nil, attributed_io: nil, attributed_memory: nil)
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: step_kind,
      grader_name: grader_name,
      job_kind: "issue",
      sample_count: 40,
      attributed_sample_count: attributed_samples,
      p90_duration_seconds: duration,
      p90_cpu_pressure: cpu,
      p90_io_pressure: io,
      p90_memory_used_percent: memory,
      p90_attributed_duration_seconds: attributed_duration,
      p90_attributed_cpu_pressure: attributed_cpu,
      p90_attributed_io_pressure: attributed_io,
      p90_attributed_memory_used_percent: attributed_memory,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: Time.current,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  before do
    profile(step_kind: "prepare", duration: 60, cpu: 5.0)
    profile(step_kind: "implement", duration: 180, cpu: 15.0)
    profile(step_kind: "grader_fanout", duration: 10, cpu: 2.0)
    profile(step_kind: "grader_collect", duration: 10, cpu: 2.0)
    profile(step_kind: "coverage_analyze", duration: 30, cpu: 5.0)
    profile(step_kind: "summarize", duration: 30, cpu: 5.0)
    profile(step_kind: "test_plan", duration: 30, cpu: 5.0)
    profile(step_kind: "pr_open", duration: 10, cpu: 2.0)
  end

  it "admits a workflow when projected pressure is within budget" do
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("within_budget")
    expect(decision.pressure.dig("candidate", "profile_count")).to be >= 8
  end

  it "includes dynamic grader profiles when predicting a grader fanout workflow" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.pressure.dig("candidate", "duration_seconds")).to be >= 2_400
    expect(decision.pressure.dig("candidate", "high_cost")).to be(true)
  end

  it "delays a medium-priority workflow when active predicted work already consumes the budget" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    active = workflow_for(state: "running")
    candidate = workflow_for

    decision = described_class.call(workflow: candidate)

    expect(active.reload).to be_running
    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.delay_until).to be_present
    expect(decision.pressure.dig("projected", "cpu_pressure")).to be >= 100.0
  end

  it "records urgent admission as an override instead of delaying for soft pressure" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    workflow_for(state: "running")
    urgent = workflow_for(priority: "urgent")

    decision = described_class.call(workflow: urgent)

    expect(decision.action).to eq("admit_now")
    expect(decision.override).to be(true)
    expect(decision.reason).to eq("urgent_priority_override")
  end

  it "requires an override when current worker health shows hard memory pressure" do
    WorkerHostHealthSample.create!(
      hostname: "worker-1",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      memory_used_percent: 97.0,
      raw_metrics: {}
    )
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("requires_override")
    expect(decision.reason).to eq("worker_memory_exhausted")
    expect(decision.details.fetch("decision_basis")).to eq("ambient_pressure")
    expect(decision.pressure.dig("host", "headroom", "memory_used_percent")).to eq(0.0)
  end

  it "does not let urgent priority bypass hard worker exhaustion" do
    WorkerHostHealthSample.create!(
      hostname: "worker-1",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      memory_used_percent: 97.0,
      raw_metrics: {}
    )
    workflow = workflow_for(priority: "urgent")

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("requires_override")
    expect(decision.override).to be(false)
  end

  it "uses attributed command profile cost ahead of host-correlated pressure when confident" do
    WorkflowStepResourceProfile.delete_all
    profile(
      step_kind: "prepare",
      duration: 1_800,
      cpu: 100.0,
      attributed_samples: 30,
      attributed_duration: 60,
      attributed_cpu: 5.0,
      attributed_io: 3.0,
      attributed_memory: 25.0
    )
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.pressure.dig("candidate", "primary_prediction_source")).to eq("command_attributed")
    expect(decision.pressure.dig("candidate", "predicted_command_cost")).to include(
      "duration_seconds" => 60,
      "cpu_pressure" => 5.0
    )
    expect(decision.pressure.dig("candidate", "fallback_reasons")).to eq([])
  end

  it "explains host-correlated fallback when command attribution is unavailable" do
    WorkflowStepResourceProfile.delete_all
    profile(step_kind: "prepare", duration: 1_800, cpu: 100.0, attributed_samples: 9, attributed_cpu: 5.0)
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.details).to include(
      "decision_basis" => "predicted_command_cost",
      "prediction_source" => "host_correlated",
      "fallback_reasons" => [ "command_attributed_profile_unavailable" ]
    )
    expect(decision.pressure.dig("candidate", "attribution_confidence_levels")).to eq([ "defaults_only" ])
  end
end
