require "rails_helper"

RSpec.describe LandingQueueProcessorJob do
  it "delegates to the processor" do
    allow(LandingQueueProcessor).to receive(:call)

    described_class.perform_now

    expect(LandingQueueProcessor).to have_received(:call)
  end

  it "is inert when polling is paused" do
    AppSetting.current.update!(polling_paused: true)
    allow(LandingQueueProcessor).to receive(:call)

    described_class.perform_now

    expect(LandingQueueProcessor).not_to have_received(:call)
  ensure
    AppSetting.current.update!(polling_paused: false)
  end

  it "retries transient landing snapshot lock conflicts inline" do
    calls = 0
    allow(LandingQueueProcessor).to receive(:call) do
      calls += 1
      raise ActiveRecord::Deadlocked, "deadlock" if calls == 1

      :ok
    end

    described_class.perform_now

    expect(calls).to eq(2)
  end

  it "requeues and requests reconciliation when lock conflicts persist" do
    allow(LandingQueueProcessor).to receive(:call).and_raise(ActiveRecord::Deadlocked, "deadlock")

    expect {
      described_class.perform_now
    }.to have_enqueued_job(described_class)
      .at(be_within(2.seconds).of(described_class::LOCK_RETRY_DELAY.from_now))
      .and have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "LandingQueueProcessorJob.lock_conflict",
        job_id: nil,
        workflow_id: nil,
        run_id: nil
      )
  end
end
