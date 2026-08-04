require "rails_helper"

RSpec.describe WorkflowStepResourceProfiles::Refresh do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:other_repository) { Factories.repository(user: user) }
  let(:now) { Time.zone.parse("2026-08-04T12:00:00Z") }

  def workflow_for(job, trigger_kind: "initial")
    Workflow.create!(
      job: job,
      user: user,
      trigger_kind: trigger_kind,
      agent_provider: "codex",
      state: "succeeded"
    )
  end

  def step_for(workflow, kind: "implement", details: {})
    Step.create!(workflow: workflow, kind: kind, position: 0, state: "succeeded", details: details)
  end

  def job_for(repository:, kind: "issue")
    attrs = { user: user, repository: repository, kind: kind, state: "running" }
    attrs[:issue_number] = nil if kind != "issue"
    Factories.job_record(**attrs)
  end

  def resource_summary(repository:, duration:, cpu: 10.0, io: 2.0, memory: 30.0, kind: "issue", step_kind: "implement", grader_name: nil, state: "succeeded", retention_limited: false, finished_at: now, process_duration: nil, process_cpu_seconds: nil, process_memory_bytes: nil, process_io_bytes: nil)
    job = job_for(repository: repository, kind: kind)
    workflow = workflow_for(job)
    step = step_for(workflow, kind: step_kind, details: grader_name ? { "name" => grader_name } : {})
    run = step.runs.create!(
      job: job,
      user: user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "codex",
      state: state,
      started_at: finished_at - duration.seconds,
      finished_at: finished_at
    )

    RunResourceSummary.create!(
      run: run,
      job: job,
      workflow: workflow,
      step: step,
      repository: repository,
      user: user,
      agent_provider: "codex",
      trigger_kind: workflow.trigger_kind,
      step_kind: step_kind,
      grader_name: grader_name,
      started_at: run.started_at,
      finished_at: finished_at,
      duration_seconds: duration,
      host_sample_count: 3,
      host_sample_confidence: "sufficient",
      host_pressure_level: "ok",
      host_pressure_max_cpu_some_percent: cpu,
      host_pressure_max_io_some_percent: io,
      host_usage_max_memory_used_percent: memory,
      process_attributed_sample_count: process_cpu_seconds.present? || process_memory_bytes.present? || process_io_bytes.present? ? 1 : 0,
      process_attributed_duration_seconds: process_duration,
      process_attributed_cpu_seconds: process_cpu_seconds,
      process_attributed_memory_bytes: process_memory_bytes,
      process_attributed_io_bytes: process_io_bytes,
      host_pressure_reasons: [],
      retention_limited: retention_limited,
      summary_version: RunResourceSummary::SUMMARY_VERSION
    )
  end

  it "uses conservative predictions until ten samples are available" do
    9.times do |index|
      resource_summary(repository: repository, duration: 60 + index, cpu: 10.0 + index, io: 1.0 + index, memory: 20.0 + index)
    end

    described_class.new(now: now).refresh_all!

    profile = WorkflowStepResourceProfile.first
    expect(profile.sample_count).to eq(9)
    expect(profile.host_pressure_sample_count).to eq(9)
    expect(profile.attribution_quality).to eq("host_correlated")
    expect(profile.p90_duration_seconds).to eq(68.0)
    expect(profile.confidence_level).to eq("defaults_only")
    expect(profile).not_to be_permits_soft_prediction
    expect(profile.conservative_prediction).to include(
      duration_seconds: WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.fetch(:duration_seconds),
      cpu_pressure: WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.fetch(:cpu_pressure),
      confidence_level: "defaults_only"
    )
  end

  it "prefers process-attributed metrics when enough attributed samples exist" do
    10.times do |index|
      resource_summary(
        repository: repository,
        duration: 60 + index,
        cpu: 90.0,
        process_duration: 20 + index,
        process_cpu_seconds: 5.0 + index,
        process_memory_bytes: (100 + index).megabytes
      )
    end

    described_class.new(now: now).refresh_all!

    profile = WorkflowStepResourceProfile.first
    expect(profile.process_attributed_sample_count).to eq(10)
    expect(profile.host_pressure_sample_count).to eq(10)
    expect(profile.attribution_quality).to eq("process_attributed")
    expect(profile.p90_process_attributed_duration_seconds).to eq(28.0)
    expect(profile.p90_host_pressure_cpu).to eq(90.0)
    expect(profile.conservative_prediction).to include(
      prediction_basis: "process_attributed",
      process_attributed_duration_seconds: 28.0,
      process_attributed_cpu_seconds: 13.0,
      host_pressure_cpu: 90.0,
      confidence_level: "soft"
    )
  end

  it "falls back to host pressure when command spans only have duration attribution" do
    10.times do |index|
      resource_summary(
        repository: repository,
        duration: 60 + index,
        cpu: 40.0 + index,
        process_duration: 20 + index
      )
    end

    described_class.new(now: now).refresh_all!

    profile = WorkflowStepResourceProfile.first
    expect(profile.process_attributed_sample_count).to eq(0)
    expect(profile.host_pressure_sample_count).to eq(10)
    expect(profile.attribution_quality).to eq("host_correlated")
    expect(profile.p90_process_attributed_duration_seconds).to be_nil
    expect(profile.conservative_prediction).to include(
      prediction_basis: "host_correlated",
      process_attributed_duration_seconds: WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.fetch(:process_attributed_duration_seconds),
      host_pressure_cpu: 48.0
    )
  end

  it "marks many host-correlated-only samples differently from process-attributed profiles" do
    30.times do |index|
      resource_summary(repository: repository, duration: 100 + index, cpu: 20.0 + index)
    end

    described_class.new(now: now).refresh_all!

    profile = WorkflowStepResourceProfile.first
    expect(profile.process_attributed_sample_count).to eq(0)
    expect(profile.host_pressure_sample_count).to eq(30)
    expect(profile.attribution_quality).to eq("host_correlated")
    expect(profile.confidence_level).to eq("normal")
    expect(profile.conservative_prediction).to include(
      prediction_basis: "host_correlated",
      host_pressure_cpu: 46.0
    )
  end

  it "builds repository-specific profiles" do
    resource_summary(repository: repository, duration: 100, cpu: 20.0)
    resource_summary(repository: other_repository, duration: 300, cpu: 80.0)

    described_class.new(now: now).refresh_all!

    expect(WorkflowStepResourceProfile.count).to eq(2)
    expect(WorkflowStepResourceProfile.find_by!(repository: repository).p50_duration_seconds).to eq(100.0)
    expect(WorkflowStepResourceProfile.find_by!(repository: other_repository).p50_duration_seconds).to eq(300.0)
  end

  it "keeps grader-specific profiles separate by grader name" do
    resource_summary(repository: repository, duration: 120, step_kind: "grader", grader_name: "rspec")
    resource_summary(repository: repository, duration: 45, step_kind: "grader", grader_name: "typecheck")

    described_class.new(now: now).refresh_all!

    expect(WorkflowStepResourceProfile.pluck(:grader_name, :p50_duration_seconds)).to contain_exactly(
      [ "rspec", 120.0 ],
      [ "typecheck", 45.0 ]
    )
  end

  it "excludes retention-limited summaries from aggregate inputs" do
    resource_summary(repository: repository, duration: 100, cpu: 10.0)
    resource_summary(repository: repository, duration: 1_000, cpu: 99.0, retention_limited: true)

    described_class.new(now: now).refresh_all!

    profile = WorkflowStepResourceProfile.first
    expect(profile.sample_count).to eq(1)
    expect(profile.p50_duration_seconds).to eq(100.0)
    expect(profile.p50_cpu_pressure).to eq(10.0)
  end

  it "retains historical profiles after detailed summaries are pruned" do
    stale_observed_at = now - 100.days
    retained = WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: "implement",
      grader_name: "",
      job_kind: "issue",
      sample_count: 40,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: stale_observed_at,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )

    described_class.new(now: now).refresh_all!

    expect(WorkflowStepResourceProfile.exists?(retained.id)).to be(true)
  end
end
