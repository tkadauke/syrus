require "rails_helper"

RSpec.describe PollingPersistenceRetry do
  let(:job) { Factories.job }

  before do
    allow(described_class).to receive(:sleep)
    @messages = []
    allow(Rails.logger).to receive(:warn) { |message| @messages << message }
  end

  it "retries a bounded number of times and emits structured retry diagnostics" do
    attempts = 0

    result = described_class.call(job: job, boundary: "mergeability") do
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, "lock wait timed out" if attempts == 1

      :persisted
    end

    expect(result).to eq(:persisted)
    expect(JSON.parse(@messages.sole)).to include(
      "event" => "github_polling_persistence_contention",
      "boundary" => "mergeability",
      "job_id" => job.id,
      "repository_id" => job.repository_id,
      "retry_number" => 1,
      "exhausted" => false
    )
  end

  it "logs exhaustion with context and re-raises the lock error" do
    expect {
      described_class.call(job: job, boundary: "pr_checks") do
        raise ActiveRecord::LockWaitTimeout, "lock wait timed out"
      end
    }.to raise_error(ActiveRecord::LockWaitTimeout, "lock wait timed out")

    expect(@messages.size).to eq(3)
    payload = JSON.parse(@messages.last)
    expect(payload).to include(
      "boundary" => "pr_checks",
      "job_slug" => job.slug,
      "retry_number" => 3,
      "max_retries" => 2,
      "exhausted" => true,
      "error_class" => "ActiveRecord::LockWaitTimeout"
    )
  end
end
