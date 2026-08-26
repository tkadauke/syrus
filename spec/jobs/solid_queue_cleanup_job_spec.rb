require "rails_helper"

RSpec.describe SolidQueueCleanupJob do
  it "clears finished SolidQueue jobs in small bounded batches" do
    # SolidQueue::Job's table isn't loaded in this single-DB test setup
    # (CLAUDE.md). Replace the class with a bare stand-in so we can
    # assert the cleanup call without hitting the missing table.
    cleanup_class = Class.new do
      class << self
        attr_accessor :id_batches, :deleted_job_ids, :limit_values, :finished_before_values, :order_values

        def clearable(finished_before:)
          finished_before_values << finished_before
          self
        end

        def order(*values)
          order_values << values
          self
        end

        def limit(value)
          limit_values << value
          self
        end

        def pluck(column)
          raise "unexpected column #{column.inspect}" unless column == :id

          id_batches.shift || []
        end

        def where(id:)
          deleted_job_ids << id
          self
        end

        def delete_all
          true
        end
      end
    end
    cleanup_class.id_batches = [ (1..100).to_a, (101..200).to_a, [] ]
    cleanup_class.deleted_job_ids = []
    cleanup_class.limit_values = []
    cleanup_class.finished_before_values = []
    cleanup_class.order_values = []
    stub_const("SolidQueue::Job", cleanup_class)
    allow_any_instance_of(described_class).to receive(:sleep)
    allow_any_instance_of(described_class).to receive(:prune_obsolete_ready_jobs)
    allow_any_instance_of(described_class).to receive(:prune_duplicate_workflow_phase_admission_jobs)

    described_class.perform_now

    expect(SolidQueue::Job.limit_values).to eq([ 100, 100, 100 ])
    expect(SolidQueue::Job.order_values).to eq([ [ :finished_at, :id ], [ :finished_at, :id ], [ :finished_at, :id ] ])
    expect(SolidQueue::Job.finished_before_values).to all(be_present)
    expect(SolidQueue::Job.deleted_job_ids).to eq([ (1..100).to_a, (101..200).to_a ])
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
    allow(job).to receive(:prune_duplicate_workflow_phase_admission_jobs)
    allow(job).to receive(:obsolete_ready_job_scope).and_return(relation)
    allow(job).to receive(:sleep)

    job.perform

    expect(relation.limit_values).to eq([ 100, 100, 100 ])
    expect(SolidQueue::ReadyExecution.deleted_job_ids).to eq([ [ 10, 11 ], [ 12 ] ])
    expect(SolidQueue::Job.deleted_job_ids).to eq([ [ 10, 11 ], [ 12 ] ])
  end

  it "keeps one pending WorkflowPhaseAdmissionJob per workflow and step" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!

    travel_to Time.zone.local(2026, 8, 24, 12, 0, 0) do
      keep_workflow = solid_queue_job(arguments: { "arguments" => [ 10153 ] }, created_at: 5.minutes.ago)
      duplicate_workflow = solid_queue_job(arguments: { "arguments" => [ 10153 ] }, created_at: 4.minutes.ago)
      keep_step = solid_queue_job(arguments: { "arguments" => [ 10153, 9 ] }, created_at: 3.minutes.ago)
      duplicate_step = solid_queue_job(arguments: { "arguments" => [ 10153, 9 ] }, created_at: 2.minutes.ago)
      other_workflow = solid_queue_job(arguments: { "arguments" => [ 10154 ] }, created_at: 1.minute.ago)

      job = described_class.new
      allow(job).to receive(:prune_finished_jobs)
      allow(job).to receive(:prune_obsolete_ready_jobs)

      job.perform

      expect(SolidQueue::Job.where(id: [ keep_workflow.id, keep_step.id, other_workflow.id ]).pluck(:id)).to contain_exactly(keep_workflow.id, keep_step.id, other_workflow.id)
      expect(SolidQueue::Job.where(id: [ duplicate_workflow.id, duplicate_step.id ])).to be_empty
      expect(SolidQueue::ReadyExecution.where(job_id: [ duplicate_workflow.id, duplicate_step.id ])).to be_empty
    end
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "runs frequently enough to spread cleanup work" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("production").fetch("clear_solid_queue_finished_jobs")).to include(
      "class" => "SolidQueueCleanupJob",
      "queue" => "cleanup",
      "schedule" => "every 5 minutes"
    )
  end

  def solid_queue_job(arguments:, created_at:)
    SolidQueue::Job.create!(
      class_name: "WorkflowPhaseAdmissionJob",
      queue_name: "control_plane",
      priority: 0,
      arguments: arguments,
      created_at: created_at,
      updated_at: created_at
    )
  end
end
