require "rails_helper"

RSpec.describe WorkerHealthRunCorrelation do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:now) { Time.zone.parse("2026-07-31T12:00:00Z") }

  def workflow(hostname: "worker-a")
    Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running", worker_hostname: hostname)
  end

  def step_for(workflow, kind: "grader", details: { "name" => "rspec" })
    Step.create!(workflow: workflow, kind: kind, position: 1, state: "succeeded", details: details)
  end

  def run_for(step, state: "succeeded", started_at: now - 10.minutes, finished_at: now - 2.minutes)
    Run.create!(
      job: job,
      user: user,
      step: step,
      trigger_kind: "initial",
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

  it "summarizes host pressure for a completed Run window" do
    wf = workflow
    step = step_for(wf)
    run = run_for(step)
    SpawnedProcess.create!(
      run: run,
      workflow: wf,
      kind: "grader",
      command: "bin/rspec",
      hostname: "worker-a",
      started_at: now - 9.minutes,
      finished_at: now - 3.minutes,
      outcome: "succeeded"
    )
    sample(observed_at: now - 8.minutes, cpu_used_percent: 92.0, cpu_pressure_some: 24.5, memory_used_percent: 55.0)
    sample(observed_at: now - 4.minutes, cpu_used_percent: 97.0, cpu_pressure_some: 31.0, memory_used_percent: 60.0)
    sample(hostname: "worker-b", observed_at: now - 4.minutes, cpu_used_percent: 100.0)

    payload = described_class.for_run(run, now: now)

    expect(payload).to include(
      run_id: run.id,
      step_kind: "grader",
      primary_hostname: "worker-a",
      sample_count: 2,
      samples_missing: false
    )
    expect(payload.dig(:summary, :cpu_used_percent)).to eq(avg: 94.5, max: 97.0)
    expect(payload.dig(:summary, :cpu_pressure_some)).to eq(avg: 27.75, max: 31.0)
    expect(payload.dig(:pressure, :level)).to eq("warning")
    expect(payload.dig(:pressure, :reasons)).to include("CPU pressure 24.5% >= 20%", "cpu 92.0% >= 90%")
    expect(payload[:processes].first).to include(kind: "grader", command: "bin/rspec")
  end

  it "uses now as the end of the window for a still-running Run" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step, state: "running", started_at: now - 20.minutes, finished_at: nil)
    sample(observed_at: now - 1.minute, memory_used_percent: 96.0)

    payload = described_class.for_run(run, now: now)

    expect(payload.dig(:range, :still_running)).to be(true)
    expect(payload.dig(:range, :finished_at)).to eq(now.iso8601)
    expect(payload.dig(:pressure, :level)).to eq("critical")
    expect(payload.dig(:pressure, :reasons)).to include("memory 96.0% >= 95%")
  end

  it "reports unknown pressure when the Run has no matching host samples" do
    wf = workflow
    step = step_for(wf, kind: "implement", details: {})
    run = run_for(step)
    sample(hostname: "worker-b", observed_at: now - 5.minutes, cpu_used_percent: 99.0)

    payload = described_class.for_run(run, now: now)

    expect(payload[:sample_count]).to eq(0)
    expect(payload[:samples_missing]).to be(true)
    expect(payload.dig(:pressure, :level)).to eq("unknown")
    expect(payload.dig(:pressure, :reasons)).to include("no retained host health samples for run window")
  end

  it "clips analysis to retained worker health history" do
    wf = workflow
    step = step_for(wf)
    run = run_for(step, started_at: now - 8.days, finished_at: now - 6.days)
    sample(observed_at: now - 8.days + 1.hour, cpu_used_percent: 99.0, cpu_pressure_some: 80.0)
    sample(observed_at: now - 6.days - 1.hour, cpu_used_percent: 91.0, cpu_pressure_some: 22.0)

    payload = described_class.for_run(run, now: now)

    expect(payload[:retention_limited]).to be(true)
    expect(payload.dig(:range, :effective_since)).to eq((now - WorkerHostHealthSample::RETAIN_AFTER).iso8601)
    expect(payload[:sample_count]).to eq(1)
    expect(payload.dig(:summary, :cpu_used_percent)).to eq(avg: 91.0, max: 91.0)
    expect(payload.dig(:pressure, :reasons)).to include("run started before retained worker health history")
  end

  describe ".for_job" do
    it "returns compact pressure counts across recent job runs" do
      wf = workflow
      step = step_for(wf)
      pressured_run = run_for(step, finished_at: now - 1.minute)
      quiet_run = run_for(step, started_at: now - 40.minutes, finished_at: now - 30.minutes)
      sample(observed_at: now - 5.minutes, cpu_pressure_some: 55.0)
      sample(observed_at: now - 35.minutes, cpu_pressure_some: 1.0)

      payload = described_class.for_job(job, now: now)

      expect(payload[:runs_analyzed]).to be >= 2
      expect(payload[:pressure_run_count]).to eq(1)
      expect(payload[:latest_pressure_runs].first[:run_id]).to eq(pressured_run.id)
      expect(payload[:latest_pressure_runs].map { |entry| entry[:run_id] }).not_to include(quiet_run.id)
    end
  end
end
