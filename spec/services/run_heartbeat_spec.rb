require "rails_helper"

RSpec.describe RunHeartbeat do
  before do
    allow(described_class).to receive(:sleep)
    allow(described_class).to receive(:rand).and_return(0.05)
  end

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

  it "uses a coarse default cadence so long-running runs do not hot-write MySQL" do
    run = create_running_run(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:00Z"))

    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:00:59Z"))).to be false
    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:01:01Z"))).to be true

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:01:01Z"))
  end

  it "can force a heartbeat even inside the throttle interval" do
    run = create_running_run(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:00Z"))

    expect(described_class.touch(run, now: Time.zone.parse("2026-08-20T12:00:05Z"), force: true)).to be true

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:05Z"))
  end

  it "skips the write when the database row was already refreshed by another process" do
    run = create_running_run(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:00Z"))
    stale_copy = Run.find(run.id)
    run.update_columns(last_heartbeat_at: Time.zone.parse("2026-08-20T12:00:59Z"))

    expect(described_class.touch(stale_copy, now: Time.zone.parse("2026-08-20T12:01:00Z"))).to be false

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:59Z"))
  end

  it "retries one transient lock timeout and records redacted structured diagnostics" do
    run = create_running_run(last_heartbeat_at: 1.minute.ago)
    relation = instance_double(ActiveRecord::Relation)
    allow(Run).to receive(:where).with(id: run.id, finished_at: nil).and_return(relation)
    attempts = 0
    allow(relation).to receive(:update_all) do
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, "sensitive database detail" if attempts == 1
      1
    end
    messages = []
    allow(Rails.logger).to receive(:warn) { |message| messages << JSON.parse(message) }

    expect(described_class.touch(run, force: true)).to be true

    expect(relation).to have_received(:update_all).twice
    expect(messages).to contain_exactly(include(
      "event" => "run_heartbeat_contention", "action" => "retry",
      "run_id" => run.id, "attempt" => 1, "exhausted" => false,
      "error_class" => "ActiveRecord::LockWaitTimeout"
    ))
    expect(messages.to_json).not_to include("sensitive database detail")
  end

  it "retries deadlocks using the same bounded policy" do
    run = create_running_run(last_heartbeat_at: 1.minute.ago)
    attempts = 0
    allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all) do
      attempts += 1
      raise ActiveRecord::Deadlocked, "deadlock" if attempts == 1
      1
    end

    expect(described_class.touch(run, force: true)).to be true
    expect(attempts).to eq(2)
  end

  it "skips one heartbeat after retry exhaustion while the durable heartbeat is fresh" do
    run = create_running_run(last_heartbeat_at: 1.minute.ago)
    allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all)
      .and_raise(ActiveRecord::LockWaitTimeout, "lock wait timed out")
    messages = []
    allow(Rails.logger).to receive(:warn) { |message| messages << JSON.parse(message) }

    expect(described_class.touch(run, force: true)).to be false

    expect(messages.pluck("action")).to eq(%w[retry retry exhausted skipped])
  end

  it "uses a recent start as the liveness signal when the first heartbeat is contended" do
    run = create_running_run(last_heartbeat_at: nil)
    run.update_columns(started_at: 1.minute.ago)
    allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all)
      .and_raise(ActiveRecord::Deadlocked, "deadlock")

    expect(described_class.touch(run, force: true)).to be false
  end

  it "raises after retry exhaustion when skipping would leave the run genuinely stale" do
    run = create_running_run(last_heartbeat_at: Run::STALE_HEARTBEAT_THRESHOLD.ago - 1.second)
    allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all)
      .and_raise(ActiveRecord::LockWaitTimeout, "lock wait timed out")

    expect { described_class.touch(run, force: true) }.to raise_error(ActiveRecord::LockWaitTimeout)
  end

  it "does not update a run that was cancelled before the heartbeat write" do
    run = create_running_run(last_heartbeat_at: 1.minute.ago)
    run.update_columns(state: "cancelled", finished_at: Time.current)

    expect(described_class.touch(run.reload, force: true)).to be false
  end

  # What matters here is that the heartbeat thread makes progress *while* the
  # block is still running, not how much wall clock passes. Sleeping a fixed
  # span and counting touches afterwards is not the same assertion: on a
  # loaded machine the thread can be starved for longer than any span worth
  # hard-coding, leaving only the synchronous touches from entry and `ensure`
  # and failing an otherwise healthy heartbeat. Block on the heartbeats
  # themselves instead -- that passes at any machine speed, and a thread that
  # never runs still fails the example on the timeout.
  it "keeps heartbeating while a blocking operation is in progress" do
    run = create_running_run(last_heartbeat_at: nil)
    heartbeats = Queue.new
    allow(described_class).to receive(:touch).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { heartbeats << :touched if kwargs[:force] }
    end

    result = described_class.during(run, interval: 0.01.seconds) do
      # One touch is synchronous on entry; the remaining two can only come
      # from the heartbeat thread running concurrently with this block.
      3.times { expect(heartbeats.pop(timeout: 10)).to eq(:touched) }
      :published
    end

    expect(result).to eq(:published)
    expect(described_class).to have_received(:touch).with(run, force: true).at_least(3).times
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
