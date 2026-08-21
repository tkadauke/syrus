require "rails_helper"

RSpec.describe SolidQueueCleanupJob do
  it "clears finished SolidQueue jobs in small bounded batches" do
    # SolidQueue::Job's table isn't loaded in this single-DB test setup
    # (CLAUDE.md). Replace the class with a bare stand-in so we can
    # assert the cleanup call without hitting the missing table.
    cleanup_class = Class.new do
      class << self
        attr_accessor :deleted_batches, :limit_values, :finished_before_values

        def clearable(finished_before:)
          finished_before_values << finished_before
          self
        end

        def limit(value)
          limit_values << value
          self
        end

        def delete_all
          deleted_batches.shift || 0
        end
      end
    end
    cleanup_class.deleted_batches = [ 100, 100, 0 ]
    cleanup_class.limit_values = []
    cleanup_class.finished_before_values = []
    stub_const("SolidQueue::Job", cleanup_class)
    allow_any_instance_of(described_class).to receive(:sleep)

    described_class.perform_now

    expect(SolidQueue::Job.limit_values).to eq([ 100, 100, 100 ])
    expect(SolidQueue::Job.finished_before_values).to all(be_present)
  end

  it "runs frequently enough to spread cleanup work" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("production").fetch("clear_solid_queue_finished_jobs")).to include(
      "class" => "SolidQueueCleanupJob",
      "queue" => "cleanup",
      "schedule" => "every 5 minutes"
    )
  end
end
