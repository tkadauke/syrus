require "rails_helper"

RSpec.describe PollingQueueCoverageCheckJob do
  before { ensure_solid_queue_test_tables! }
  after { clear_solid_queue_test_tables! }

  def worker_process(queues:, hostname: "syrus-worker-1")
    SolidQueue::Process.create!(
      kind: "Worker",
      name: "worker-#{SecureRandom.hex(4)}",
      hostname: hostname,
      pid: rand(1000..9999),
      last_heartbeat_at: Time.current,
      metadata: { queues: queues.join(",") }
    )
  end

  describe "#perform" do
    it "logs an error when no worker process anywhere consumes the polling queue" do
      worker_process(queues: %w[runs merges])

      expect(Rails.logger).to receive(:error).with(/no live worker process.*consumes the `polling` queue/)

      described_class.perform_now
    end

    it "logs an error when there are no worker processes at all" do
      expect(Rails.logger).to receive(:error).with(/no live worker process/)

      described_class.perform_now
    end

    it "does not log when at least one worker process consumes the polling queue (single-host style)" do
      worker_process(queues: %w[resume-abc runs merges chat control_plane polling indexing cleanup])

      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now
    end

    it "does not log when only the home tier consumes polling and the compute tier does not (split deployment)" do
      worker_process(queues: %w[resume-abc control_plane], hostname: "home-1")
      worker_process(queues: %w[polling], hostname: "home-1")
      worker_process(queues: %w[resume-xyz runs], hostname: "compute-1")
      worker_process(queues: %w[merges], hostname: "compute-1")

      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now
    end

    it "does not raise and skips the check when the Solid Queue tables are unreachable" do
      allow(SolidQueue::Process).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "no such table")

      expect(Rails.logger).not_to receive(:error)

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
