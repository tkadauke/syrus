require "rails_helper"

RSpec.describe RunResourceSummaries::Builder do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:now) { Time.zone.parse("2026-08-04T12:00:00Z") }

  def workflow(hostname: "worker-a", trigger_kind: "initial")
    Workflow.create!(
      job: job,
      user: user,
      trigger_kind: trigger_kind,
      agent_provider: "codex",
      state: "running",
      worker_hostname: hostname
    )
  end

  def step_for(workflow, kind: "grader", details: { "name" => "rspec" })
    Step.create!(workflow: workflow, kind: kind, position: 0, state: "running", details: details)
  end

  def run_for(step, state: "succeeded", started_at: now - 8.minutes, finished_at: now)
    step.runs.create!(
      job: job,
      user: user,
      trigger_kind: step.workflow.trigger_kind,
      agent_provider: "codex",
      state: state,
      started_at: started_at,
      finished_at: finished_at
    )
  end

  def sample(hostname: "worker-a", observed_at:, **attrs)
    WorkerHostHealthSample.create!({
      hostname: hostname,
      role: "worker",
      version: "abc123",
      observed_at: observed_at
    }.merge(attrs))
  end

  it "persists a durable summary for a completed run" do
    wf = workflow
    step = step_for(wf)
    run = run_for(step)
    SpawnedProcess.create!(
      run: run,
      workflow: wf,
      kind: "grader",
      command: "bin/rspec",
      hostname: "worker-a",
      started_at: now - 7.minutes,
      finished_at: now - 1.minute,
      outcome: "succeeded"
    )
    CommandSpan.create!(
      job: job,
      workflow: wf,
      step: step,
      run: run,
      sequence: 1,
      name: "rspec",
      command_excerpt: "bin/rspec",
      hostname: "worker-a",
      started_at: now - 7.minutes,
      finished_at: now - 1.minute,
      duration_ms: 360_000,
      outcome: "succeeded"
    )
    sample(observed_at: now - 6.minutes, cpu_used_percent: 92.0, cpu_pressure_some: 24.0, memory_used_percent: 55.0, io_pressure_some: 3.0)
    sample(observed_at: now - 2.minutes, cpu_used_percent: 96.0, cpu_pressure_some: 30.0, memory_used_percent: 65.0, io_pressure_some: 5.0, data_root_used_percent: 71.0)
    sample(hostname: "worker-b", observed_at: now - 2.minutes, cpu_used_percent: 100.0)

    summary = described_class.new(run: run, now: now).refresh!

    expect(summary).to have_attributes(
      run: run,
      job: job,
      workflow: wf,
      step: step,
      repository: repository,
      user: user,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: "grader",
      grader_name: "rspec",
      hostname: "worker-a",
      duration_seconds: 480.0,
      host_sample_count: 2,
      sample_confidence: "insufficient",
      avg_cpu_used_percent: 94.0,
      max_cpu_used_percent: 96.0,
      avg_cpu_pressure: 27.0,
      max_cpu_pressure: 30.0,
      avg_memory_used_percent: 60.0,
      max_memory_used_percent: 65.0,
      avg_io_pressure: 4.0,
      max_io_pressure: 5.0,
      max_data_root_used_percent: 71.0,
      spawned_process_count: 1,
      command_span_count: 1,
      resource_pressure_level: "warning",
      retention_limited: false,
      summary_version: RunResourceSummary::SUMMARY_VERSION
    )
    expect(summary.resource_pressure_reasons).to include("CPU pressure 24.0% >= 20%", "cpu 92.0% >= 90%")
  end

  it "marks one or two samples as low confidence for runs under 60 seconds" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step, started_at: now - 45.seconds, finished_at: now)
    sample(observed_at: now - 30.seconds, cpu_used_percent: 12.0)
    sample(observed_at: now - 10.seconds, cpu_used_percent: 18.0)

    summary = described_class.new(run: run, now: now).refresh!

    expect(summary.host_sample_count).to eq(2)
    expect(summary.sample_confidence).to eq("low")
    expect(summary.resource_pressure_level).to eq("ok")
  end

  it "requires at least ten samples for runs ten minutes or longer" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step, started_at: now - 15.minutes, finished_at: now)
    9.times do |index|
      sample(observed_at: now - 14.minutes + index.minutes, cpu_used_percent: 20.0 + index)
    end

    summary = described_class.new(run: run, now: now).refresh!

    expect(summary.host_sample_count).to eq(9)
    expect(summary.sample_confidence).to eq("insufficient")
    expect(summary.resource_pressure_level).to eq("ok")
  end

  it "persists unknown pressure when no samples exist" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step)
    sample(hostname: "worker-b", observed_at: now - 2.minutes, cpu_used_percent: 99.0)

    summary = described_class.new(run: run, now: now).refresh!

    expect(summary.host_sample_count).to eq(0)
    expect(summary.sample_confidence).to eq("unknown")
    expect(summary.resource_pressure_level).to eq("unknown")
    expect(summary.resource_pressure_reasons).to include("no retained host health samples for run window")
  end

  it "refreshes an existing row for an active run using now as the end of the window" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step, state: "running", started_at: now - 2.minutes, finished_at: nil)
    sample(observed_at: now - 1.minute, memory_used_percent: 96.0)

    first = described_class.new(run: run, now: now).refresh!
    second = described_class.new(run: run, now: now + 1.minute).refresh!

    expect(second.id).to eq(first.id)
    expect(RunResourceSummary.where(run: run).count).to eq(1)
    expect(second.finished_at).to eq(now + 1.minute)
    expect(second.duration_seconds).to eq(180.0)
    expect(second.resource_pressure_level).to eq("critical")
  end

  it "marks summaries retention-limited when the run starts before retained host history" do
    wf = workflow
    step = step_for(wf)
    run = run_for(step, started_at: now - 8.days, finished_at: now - 6.days)
    sample(observed_at: now - 6.days - 1.hour, cpu_used_percent: 91.0)

    summary = described_class.new(run: run, now: now).refresh!

    expect(summary.retention_limited).to be(true)
    expect(summary.resource_pressure_reasons).to include("run started before retained worker health history")
  end
end
