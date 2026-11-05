require "rails_helper"

RSpec.describe WorkflowPhaseAdmissionJob do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it "enqueues one recheck per workflow while the debounce key is live" do
    expect {
      described_class.enqueue_once(123)
      described_class.enqueue_once(123)
    }.to have_enqueued_job(described_class).once
  end

  it "can force an immediate recheck while the debounce key is live" do
    expect {
      described_class.enqueue_once(123, wait_until: 5.minutes.from_now)
      described_class.enqueue_once(123, force: true)
    }.to have_enqueued_job(described_class).twice
  end

  it "keeps workflow-level and step-level rechecks separate" do
    expect {
      described_class.enqueue_once(123)
      described_class.enqueue_once(123, 456)
    }.to have_enqueued_job(described_class).twice
  end

  it "passes through schedule options on the first enqueue" do
    wait_until = 5.minutes.from_now

    expect {
      described_class.enqueue_once(123, wait_until: wait_until, priority: 10)
    }.to have_enqueued_job(described_class).with(123).at(wait_until).on_queue("control_plane")
  end

  it "releases the debounce key before resuming so blocked work can enqueue its next recheck" do
    described_class.enqueue_once(123)
    clear_enqueued_jobs
    allow(WorkUnits::DeferredPhaseResume).to receive(:call) do
      described_class.enqueue_once(123, wait: 1.minute)
    end

    expect {
      described_class.perform_now(123)
    }.to have_enqueued_job(described_class).with(123).once
  end

  it "retries transient lock conflicts with a fresh phase resume call" do
    calls = 0
    allow(WorkUnits::DeferredPhaseResume).to receive(:call) do
      calls += 1
      raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

      :resumed
    end

    expect(described_class.perform_now(123, 456)).to eq(:resumed)
    expect(calls).to eq(2)
  end

  it "queues a later recheck when lock conflicts persist" do
    allow(WorkUnits::DeferredPhaseResume)
      .to receive(:call)
      .and_raise(ActiveRecord::LockWaitTimeout, "lock wait timed out")

    expect {
      described_class.perform_now(123, 456)
    }.to have_enqueued_job(described_class)
      .with(123, 456)
      .at(be_within(2.seconds).of(described_class::LOCK_RETRY_DELAY.from_now))

    expect(WorkUnits::DeferredPhaseResume)
      .to have_received(:call)
      .with(123, 456)
      .exactly(described_class::LOCK_RETRY_ATTEMPTS + 1).times
  end
end
