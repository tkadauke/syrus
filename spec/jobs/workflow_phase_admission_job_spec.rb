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
end
