require "rails_helper"

RSpec.describe WorkflowAdmissionBudget do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def workflow_for(priority: "medium", state: "queued", trigger_kind: "initial")
    job = Factories.job_record(user: user, repository: repository, priority: priority, state: "queued")
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "codex")
    workflow.update!(state: state, trigger_kind: trigger_kind)
    workflow
  end

  def profile(step_kind:, duration: 60, cpu: 5.0, io: 5.0, memory: 20.0, grader_name: "", trigger_kind: "initial", job_kind: "issue", attributed_samples: 0, attributed_duration: nil, attributed_cpu: nil, attributed_io: nil, attributed_memory: nil)
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: trigger_kind,
      step_kind: step_kind,
      grader_name: grader_name,
      job_kind: job_kind,
      sample_count: 40,
      attributed_sample_count: attributed_samples,
      process_attributed_sample_count: attributed_samples,
      host_pressure_sample_count: 40,
      attribution_quality: attributed_samples.positive? ? "mixed" : "host_correlated",
      p90_duration_seconds: duration,
      p90_cpu_pressure: cpu,
      p90_io_pressure: io,
      p90_memory_used_percent: memory,
      p90_process_attributed_duration_seconds: attributed_duration,
      p90_process_attributed_cpu_percent: attributed_cpu,
      p90_process_attributed_io_bytes: attributed_io,
      p90_process_attributed_memory_bytes: attributed_memory,
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

  def worker_sample(hostname: "worker-1", cpu: 5.0, io: 5.0, memory: 40.0, disk: 25.0)
    WorkerHostHealthSample.create!(
      hostname: hostname,
      role: "worker",
      version: "test",
      observed_at: Time.current,
      cpu_pressure_some: cpu,
      io_pressure_some: io,
      memory_used_percent: memory,
      data_root_used_percent: disk,
      raw_metrics: {}
    )
  end

  def seed_low_cost_profiles(except: [], attributed: false)
    %w[prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open].each do |step_kind|
      next if except.include?(step_kind)

      if attributed
        profile(
          step_kind: step_kind,
          duration: 10,
          cpu: 1.0,
          io: 1.0,
          memory: 10.0,
          attributed_samples: 30,
          attributed_duration: 10,
          attributed_cpu: 1.0,
          attributed_io: 1.0,
          attributed_memory: 10.0
        )
      else
        profile(step_kind: step_kind, duration: 10, cpu: 1.0, io: 1.0, memory: 10.0)
      end
    end
  end

  before do
    seed_low_cost_profiles
  end

  it "admits a workflow when projected pressure is within budget" do
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("within_budget")
    expect(decision.details).to include(
      "decision_basis" => "fallback_host_correlated_profile",
      "prediction_source" => "host_correlated"
    )
    expect(decision.pressure.dig("candidate", "profile_count")).to be >= 8
  end

  it "includes dynamic grader profiles when predicting a grader fanout workflow" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.pressure.dig("candidate", "duration_seconds")).to be >= 2_400
    expect(decision.pressure.dig("candidate", "high_cost")).to be(true)
  end

  it "records conservative defaults while bootstrapping steps with no matching profile" do
    WorkflowStepResourceProfile.delete_all
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("bootstrap_missing_profiles")
    expect(decision.pressure.dig("candidate", "profile_count")).to eq(0)
    expect(decision.pressure.dig("candidate", "missing_profile_count")).to be >= 1
    expect(decision.pressure.dig("candidate", "fallback_reasons")).to include("missing_workflow_step_resource_profile")
    expect(decision.pressure.dig("candidate", "predicted_command_cost", "cpu_pressure")).to be >= WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.fetch(:cpu_pressure)
  end

  it "delays missing-profile work when another running workflow is already consuming the bootstrap budget" do
    workflow_for(state: "running")
    candidate = workflow_for(trigger_kind: "retry")

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.pressure.dig("active", "workflow_count")).to eq(1)
  end

  it "does not count queued workflows as active predicted pressure" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 20.0, io: 10.0, memory: 40.0)
    queued_peer = workflow_for(state: "queued")
    candidate = workflow_for(state: "queued")

    decision = described_class.call(workflow: candidate)

    expect(queued_peer.reload).to be_queued
    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("within_budget")
    expect(decision.pressure.dig("active", "workflow_count")).to eq(0)
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

  it "admits a medium-priority auto-merge below the healthy-worker floor despite conservative default pressure" do
    WorkerHostHealthSample.delete_all
    worker_sample(hostname: "worker-1")
    WorkflowStepResourceProfile.delete_all
    %w[mergeability_preflight grader_fanout grader_collect push auto_merge].each do |step_kind|
      profile(step_kind: step_kind, trigger_kind: "auto_merge", duration: 20, cpu: 2.0, io: 2.0, memory: 20.0)
    end
    landing_job = Factories.job_record(
      user: user,
      repository: repository,
      state: "landing",
      priority: "medium",
      issue_number: 77,
      pr_number: 77,
      branch_name: "syrus/issue-77"
    )
    workflow = Workflows::AutoMerge.instantiate(job: landing_job, agent_provider: "codex")

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("minimum_progress_floor")
    expect(decision.override).to be(true)
    expect(decision.details).to include(
      "decision_basis" => "minimum_progress_floor",
      "minimum_progress_floor_used" => true,
      "minimum_progress_floor_reason" => "predicted_budget_pressure_high",
      "healthy_worker_count" => 1,
      "active_agentic_run_count" => 0,
      "minimum_progress_floor_capacity" => 1
    )
    expect(decision.details.fetch("soft_pressure_gates_present")).to include("predicted_budget_pressure_high")
  end

  it "resumes delaying once running agentic work reaches the healthy-worker floor" do
    WorkerHostHealthSample.delete_all
    worker_sample(hostname: "worker-1")
    WorkflowStepResourceProfile.delete_all
    profile(step_kind: "prepare", trigger_kind: "retry", duration: 20, cpu: 2.0, io: 2.0, memory: 20.0)
    active = workflow_for(state: "running")
    active_step = active.steps.find_by!(kind: "implement")
    active_step.runs.create!(
      job: active.job,
      user: active.job.user,
      trigger_kind: active.trigger_kind,
      agent_provider: active.agent_provider,
      state: "running",
      started_at: Time.current
    )
    candidate = workflow_for(trigger_kind: "retry")

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.details).to include(
      "healthy_worker_count" => 1,
      "active_agentic_run_count" => 1,
      "minimum_progress_floor_capacity" => 1,
      "minimum_progress_floor_available" => false
    )
  end

  it "keeps a minimum-progress floor slot occupied after prepare until the first agentic run exists" do
    WorkerHostHealthSample.delete_all
    worker_sample(hostname: "worker-1")
    WorkflowStepResourceProfile.delete_all
    profile(step_kind: "prepare", trigger_kind: "retry", duration: 20, cpu: 2.0, io: 2.0, memory: 20.0)
    admitted = workflow_for(state: "running")
    admitted.first_step.update_columns(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago, updated_at: Time.current)
    admitted.update!(
      artifacts: {
        "workflow_admission_override" => {
          "action" => "admit_now",
          "reason" => "minimum_progress_floor",
          "override" => true
        }
      }
    )
    expect(admitted.reload.artifact("workflow_admission_override")).to include("reason" => "minimum_progress_floor")
    candidate = workflow_for(trigger_kind: "retry")

    budget = described_class.new(workflow: candidate)
    expect(budget.send(:active_minimum_progress_handoff_count)).to eq(1)
    decision = budget.call

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.details).to include(
      "active_agentic_run_count" => 0,
      "active_minimum_progress_handoff_count" => 1,
      "minimum_progress_floor_capacity" => 1,
      "minimum_progress_floor_slots_used" => 1,
      "minimum_progress_floor_available" => false
    )
  end

  it "releases a minimum-progress handoff slot once the first agentic run has been created" do
    WorkerHostHealthSample.delete_all
    worker_sample(hostname: "worker-1")
    WorkflowStepResourceProfile.delete_all
    %w[prepare implement].each do |step_kind|
      profile(step_kind: step_kind, trigger_kind: "retry", duration: 20, cpu: 2.0, io: 2.0, memory: 20.0)
    end
    admitted = workflow_for(state: "running")
    admitted.first_step.update_columns(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago, updated_at: Time.current)
    implement_step = admitted.steps.find_by!(kind: "implement")
    implement_step.runs.create!(
      job: admitted.job,
      user: admitted.job.user,
      trigger_kind: admitted.trigger_kind,
      agent_provider: admitted.agent_provider,
      state: "succeeded",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago
    )
    admitted.update!(
      artifacts: {
        "workflow_admission_override" => {
          "action" => "admit_now",
          "reason" => "minimum_progress_floor",
          "override" => true
        }
      }
    )
    candidate = workflow_for(trigger_kind: "retry")

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("minimum_progress_floor")
    expect(decision.details).to include(
      "active_agentic_run_count" => 0,
      "active_minimum_progress_handoff_count" => 0,
      "minimum_progress_floor_slots_used" => 0
    )
  end

  it "records urgent admission as an override instead of delaying for soft pressure" do
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    workflow_for(state: "running")
    urgent = workflow_for(priority: "urgent")

    decision = described_class.call(workflow: urgent)

    expect(decision.action).to eq("admit_now")
    expect(decision.override).to be(true)
    expect(decision.reason).to eq("urgent_priority_override")
    expect(decision.details).to include(
      "decision_basis" => "urgent_priority_override",
      "prediction_source" => "host_correlated"
    )
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

  it "does not bypass hard worker exhaustion when admission control is disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
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
  end

  it "bypasses soft host pressure when admission control is disabled" do
    actor = Factories.user(email_address: "admin@example.com")
    AppSetting.current.update!(
      workflow_admission_control_enabled: false,
      workflow_admission_control_changed_at: Time.current,
      workflow_admission_control_changed_by_user: actor
    )
    WorkerHostHealthSample.create!(
      hostname: "worker-1",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      cpu_pressure_some: 90.0,
      raw_metrics: {}
    )
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("admission_control_disabled")
    expect(decision.override).to be(true)
    expect(decision.details).to include(
      "admission_control_disabled" => true,
      "admission_control_disabled_by" => "admin@example.com"
    )
    expect(decision.details.fetch("bypassed_gates")).to include("worker_host_pressure_high")
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
    seed_low_cost_profiles(except: [ "prepare" ], attributed: true)
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
      "duration_seconds" => 130,
      "cpu_pressure" => 12.0,
      "io_pressure" => 10.0,
      "memory_used_percent" => 25.0,
      "source" => "command_attributed",
      "confidence" => "process_attributed"
    )
    expect(decision.pressure.dig("candidate", "process_attributed_cost")).to include(
      "duration_seconds" => 130,
      "cpu_percent" => 12.0,
      "memory_bytes" => 25,
      "io_bytes" => 10
    )
    expect(decision.pressure.dig("candidate", "fallback_reasons")).to eq([])
  end

  it "explains host-correlated fallback when command attribution is unavailable" do
    WorkflowStepResourceProfile.delete_all
    seed_low_cost_profiles(except: [ "prepare" ])
    profile(step_kind: "prepare", duration: 1_800, cpu: 100.0, attributed_samples: 9, attributed_cpu: 5.0)
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.details).to include(
      "decision_basis" => "fallback_host_correlated_profile",
      "prediction_source" => "host_correlated"
    )
    expect(decision.details.fetch("fallback_reasons")).to include("command_attributed_profile_unavailable")
    expect(decision.pressure.dig("candidate", "attribution_confidence_levels")).to eq([ "defaults_only" ])
  end

  it "bypasses conservative default prediction delays when admission control is disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
    WorkflowStepResourceProfile.delete_all
    workflow_for(state: "running")
    candidate = workflow_for(trigger_kind: "retry")

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("admission_control_disabled")
    expect(decision.details.fetch("bypassed_gates")).to include(
      "bootstrap_missing_profiles",
      "predicted_budget_pressure_high"
    )
  end

  it "bypasses pending high-cost and repository concurrency throttles when admission control is disabled" do
    AppSetting.current.update!(workflow_admission_control_enabled: false)
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 20.0, io: 10.0, memory: 40.0)
    2.times { workflow_for(state: "running") }
    candidate = workflow_for

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("admit_now")
    expect(decision.reason).to eq("admission_control_disabled")
    expect(decision.details.fetch("bypassed_gates")).to include(
      "pending_high_cost_work",
      "repository_concurrency_budget_exhausted"
    )
  end

  it "re-enabling admission restores normal budgeting behavior" do
    AppSetting.current.update!(workflow_admission_control_enabled: true)
    profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
    workflow_for(state: "running")
    candidate = workflow_for

    decision = described_class.call(workflow: candidate)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
  end

  it "labels mixed-source pressure by the source that drives the budget decision" do
    WorkflowStepResourceProfile.delete_all
    seed_low_cost_profiles(except: %w[prepare implement], attributed: true)
    profile(
      step_kind: "prepare",
      duration: 60,
      cpu: 90.0,
      attributed_samples: 30,
      attributed_duration: 20,
      attributed_cpu: 2.0
    )
    profile(step_kind: "implement", duration: 1_800, cpu: 120.0, io: 10.0, memory: 30.0)
    workflow = workflow_for

    decision = described_class.call(workflow: workflow)

    expect(decision.action).to eq("delay_until")
    expect(decision.reason).to eq("predicted_budget_pressure_high")
    expect(decision.details).to include(
      "decision_basis" => "fallback_host_correlated_profile",
      "prediction_source" => "host_correlated"
    )
    expect(decision.pressure.dig("candidate", "prediction_sources")).to include(
      "command_attributed" => 7,
      "host_correlated" => 1
    )
    expect(decision.pressure.dig("candidate", "prediction_source_contributions", "host_correlated", "cpu_pressure")).to eq(120.0)
  end

  describe "telemetry_state" do
    it "does not hard-block admission when host telemetry is absent but step profiles are clean" do
      WorkerHostHealthSample.delete_all
      workflow = workflow_for

      decision = described_class.call(workflow: workflow)

      expect(decision.action).to eq("admit_now")
      expect(decision.action).not_to eq("requires_override")
      expect(decision.pressure.dig("host", "telemetry_state")).to eq("absent")
      expect(decision.pressure.dig("host", "sample_count")).to eq(0)
      expect(decision.pressure.dig("host", "max_cpu_pressure")).to eq(0.0)
      expect(decision.pressure.dig("host", "max_memory_used_percent")).to eq(0.0)
      expect(decision.details.fetch("telemetry_state")).to eq("absent")
    end

    it "still governs admission by profile-based pressure when host telemetry is absent" do
      WorkerHostHealthSample.delete_all
      profile(step_kind: "grader", grader_name: "production-build-boot", duration: 2_400, cpu: 70.0, io: 40.0, memory: 70.0)
      active = workflow_for(state: "running")
      candidate = workflow_for

      decision = described_class.call(workflow: candidate)

      expect(active.reload).to be_running
      expect(decision.action).to eq("delay_until")
      expect(decision.reason).to eq("predicted_budget_pressure_high")
      expect(decision.reason).not_to eq("worker_host_pressure_high")
      expect(decision.pressure.dig("host", "telemetry_state")).to eq("absent")
      expect(decision.pressure.dig("host", "max_cpu_pressure")).to eq(0.0)
      expect(decision.details.fetch("telemetry_state")).to eq("absent")
    end

    it "requires an override from genuinely maxed-out hosts, not merely from missing telemetry" do
      WorkerHostHealthSample.delete_all
      workflow = workflow_for
      expect(described_class.call(workflow: workflow).action).to eq("admit_now")

      WorkerHostHealthSample.create!(
        hostname: "worker-1",
        role: "worker",
        version: "test",
        observed_at: Time.current,
        memory_used_percent: 97.0,
        raw_metrics: {}
      )
      maxed_out = workflow_for

      decision = described_class.call(workflow: maxed_out)

      expect(decision.action).to eq("requires_override")
      expect(decision.reason).to eq("worker_memory_exhausted")
      expect(decision.pressure.dig("host", "telemetry_state")).to eq("present")
    end

    it "labels samples outside the sampling window as stale rather than absent" do
      WorkerHostHealthSample.delete_all
      WorkerHostHealthSample.create!(
        hostname: "worker-1",
        role: "worker",
        version: "test",
        observed_at: 10.minutes.ago,
        cpu_pressure_some: 5.0,
        memory_used_percent: 20.0,
        data_root_used_percent: 20.0,
        raw_metrics: {}
      )
      workflow = workflow_for

      decision = described_class.call(workflow: workflow)

      expect(decision.pressure.dig("host", "telemetry_state")).to eq("stale")
      expect(decision.pressure.dig("host", "sample_count")).to eq(0)
      expect(decision.pressure.dig("host", "max_cpu_pressure")).to eq(0.0)
    end

    it "labels fresh samples within the sampling window as present" do
      WorkerHostHealthSample.delete_all
      worker_sample(hostname: "worker-1")
      workflow = workflow_for

      decision = described_class.call(workflow: workflow)

      expect(decision.pressure.dig("host", "telemetry_state")).to eq("present")
      expect(decision.pressure.dig("host", "sample_count")).to eq(1)
    end
  end
end
