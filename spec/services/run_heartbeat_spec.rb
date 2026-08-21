require "rails_helper"

RSpec.describe RunHeartbeat do
  it "touches a running run with no heartbeat" do
    run = create_running_run(last_heartbeat_at: nil)

    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:00:00Z"))).to be true

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:00Z"))
  end

  it "skips recent heartbeats by default" do
    run = create_running_run(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:00Z"))

    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:00:05Z"))).to be false

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:00Z"))
  end

  it "can force a heartbeat even inside the throttle interval" do
    run = create_running_run(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:00Z"))

    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:00:05Z"), force: true)).to be true

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:05Z"))
  end

  def create_running_run(last_heartbeat_at:)
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
    Run.create!(
      job: job,
      step: step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "running",
      started_at: Time.zone.parse("2026-08-20T11:59:00Z"),
      last_heartbeat_at: last_heartbeat_at
    )
  end
end
