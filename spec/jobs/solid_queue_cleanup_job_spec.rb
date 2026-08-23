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
    allow_any_instance_of(described_class).to receive(:prune_obsolete_ready_jobs)

    described_class.perform_now

    expect(SolidQueue::Job.limit_values).to eq([ 100, 100, 100 ])
    expect(SolidQueue::Job.finished_before_values).to all(be_present)
  end

  it "clears stale ready jobs from obsolete queues in bounded batches" do
    relation = Class.new do
      class << self
        attr_accessor :id_batches, :limit_values

        def limit(value)
          limit_values << value
          self
        end

        def pluck(column)
          raise "unexpected column #{column.inspect}" unless column == :id

          id_batches.shift || []
        end
      end
    end
    relation.id_batches = [ [ 10, 11 ], [ 12 ], [] ]
    relation.limit_values = []

    ready_execution_class = Class.new do
      class << self
        attr_accessor :deleted_job_ids

        def where(job_id:)
          deleted_job_ids << job_id
          self
        end

        def delete_all
          true
        end
      end
    end
    ready_execution_class.deleted_job_ids = []

    job_class = Class.new do
      class << self
        attr_accessor :deleted_job_ids

        def where(id:)
          deleted_job_ids << id
          self
        end

        def delete_all
          true
        end
      end
    end
    job_class.deleted_job_ids = []

    stub_const("SolidQueue::ReadyExecution", ready_execution_class)
    stub_const("SolidQueue::Job", job_class)

    job = described_class.new
    allow(job).to receive(:prune_finished_jobs)
    allow(job).to receive(:obsolete_ready_job_scope).and_return(relation)
    allow(job).to receive(:sleep)

    job.perform

    expect(relation.limit_values).to eq([ 100, 100, 100 ])
    expect(SolidQueue::ReadyExecution.deleted_job_ids).to eq([ [ 10, 11 ], [ 12 ] ])
    expect(SolidQueue::Job.deleted_job_ids).to eq([ [ 10, 11 ], [ 12 ] ])
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
