require "rails_helper"

# Test fixture lives outside the example group so ActiveJob can
# discover the constant by name when serializing the enqueued job.
class SkipIfPendingTestJob < ApplicationJob
  include SkipIfPending
  queue_as :control_plane
  def perform(*); end
end

RSpec.describe SkipIfPending do
  # SolidQueue::Job's table lives on the queue DB which isn't loaded
  # in this single-DB test setup (CLAUDE.md). Stub the constant with
  # a bare class so referencing `.where(...)` doesn't trigger schema
  # introspection against a table that doesn't exist.
  let(:relation) { double("relation", exists?: false, limit: pending_jobs) }
  let(:pending_jobs) { [] }
  before do
    connection = double("connection", adapter_name: "SQLite")
    fake_job_class = Class.new do
      def self.where(*); end
      def self.connection; end
    end
    stub_const("SolidQueue::Job", fake_job_class)
    allow(SolidQueue::Job).to receive(:connection).and_return(connection)
    allow(SolidQueue::Job).to receive(:where)
      .with(class_name: "SkipIfPendingTestJob", finished_at: nil)
      .and_return(relation)
  end

  describe "no-arg perform_later" do
    it "enqueues normally when no instance is pending" do
      expect { SkipIfPendingTestJob.perform_later }
        .to have_enqueued_job(SkipIfPendingTestJob)
    end

    it "skips enqueue when an unfinished instance already exists" do
      allow(relation).to receive(:exists?).and_return(true)
      expect(Syrus::Metrics.counter(:syrus_skip_if_pending_skips_total)).to receive(:increment).with(
        tags: {
          job_class: "SkipIfPendingTestJob",
          queue: "control_plane",
          mode: "class"
        }
      )

      expect { SkipIfPendingTestJob.perform_later }
        .not_to have_enqueued_job(SkipIfPendingTestJob)
    end
  end

  describe "with arguments" do
    it "enqueues when no pending job has the same positional args" do
      expect { SkipIfPendingTestJob.perform_later(42) }
        .to have_enqueued_job(SkipIfPendingTestJob).with(42)
    end

    it "skips enqueue when a pending job has the same positional args" do
      allow(relation).to receive(:limit).with(1_000).and_return([
        double("solid queue job", arguments: { "arguments" => [ 42 ] })
      ])
      expect(Syrus::Metrics.counter(:syrus_skip_if_pending_skips_total)).to receive(:increment).with(
        tags: {
          job_class: "SkipIfPendingTestJob",
          queue: "control_plane",
          mode: "arguments"
        }
      )

      expect { SkipIfPendingTestJob.perform_later(42) }
        .not_to have_enqueued_job(SkipIfPendingTestJob)
    end

    it "does not skip enqueue when only different positional args are pending" do
      allow(relation).to receive(:limit).with(1_000).and_return([
        double("solid queue job", arguments: { "arguments" => [ 41 ] })
      ])

      expect { SkipIfPendingTestJob.perform_later(42) }
        .to have_enqueued_job(SkipIfPendingTestJob).with(42)
    end

    it "bypasses the guard for keyword args" do
      expect(relation).not_to receive(:limit)
      expect { SkipIfPendingTestJob.perform_later(foo: "bar") }
        .to have_enqueued_job(SkipIfPendingTestJob)
    end
  end
end
