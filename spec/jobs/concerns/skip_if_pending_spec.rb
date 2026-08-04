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
  let(:relation) { double("relation", exists?: false) }
  before do
    fake_job_class = Class.new do
      def self.where(*); end
    end
    stub_const("SolidQueue::Job", fake_job_class)
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
      expect { SkipIfPendingTestJob.perform_later }
        .not_to have_enqueued_job(SkipIfPendingTestJob)
    end
  end

  describe "with arguments" do
    it "bypasses the guard for positional args" do
      expect(SolidQueue::Job).not_to receive(:where)
      expect { SkipIfPendingTestJob.perform_later(42) }
        .to have_enqueued_job(SkipIfPendingTestJob).with(42)
    end

    it "bypasses the guard for keyword args" do
      expect(SolidQueue::Job).not_to receive(:where)
      expect { SkipIfPendingTestJob.perform_later(foo: "bar") }
        .to have_enqueued_job(SkipIfPendingTestJob)
    end
  end
end
