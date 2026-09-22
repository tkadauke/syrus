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
    allow_any_instance_of(described_class).to receive(:prune_dead_resume_ready_executions)
    allow_any_instance_of(described_class).to receive(:prune_orphaned_jobs)
    allow_any_instance_of(described_class).to receive(:prune_duplicate_workflow_phase_admission_jobs)
    allow_any_instance_of(described_class).to receive(:prune_duplicate_polling_jobs)

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
    allow(job).to receive(:prune_dead_resume_ready_executions)
    allow(job).to receive(:prune_orphaned_jobs)
    allow(job).to receive(:prune_duplicate_workflow_phase_admission_jobs)
    allow(job).to receive(:prune_duplicate_polling_jobs)
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
      allow(job).to receive(:prune_duplicate_polling_jobs)

      job.perform

      expect(SolidQueue::Job.where(id: [ keep_workflow.id, keep_step.id, other_workflow.id ]).pluck(:id)).to contain_exactly(keep_workflow.id, keep_step.id, other_workflow.id)
      expect(SolidQueue::Job.where(id: [ duplicate_workflow.id, duplicate_step.id ])).to be_empty
      expect(SolidQueue::ReadyExecution.where(job_id: [ duplicate_workflow.id, duplicate_step.id ])).to be_empty
    end
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "keeps one pending polling job per class and serialized argument list" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!

    travel_to Time.zone.local(2026, 9, 13, 12, 0, 0) do
      keep_pr = solid_queue_job(
        class_name: "PollPullRequestJob",
        queue_name: "polling",
        arguments: { "arguments" => [ 4795 ] },
        created_at: 5.minutes.ago
      )
      duplicate_pr = solid_queue_job(
        class_name: "PollPullRequestJob",
        queue_name: "polling",
        arguments: { "arguments" => [ 4795 ] },
        created_at: 4.minutes.ago
      )
      other_pr = solid_queue_job(
        class_name: "PollPullRequestJob",
        queue_name: "polling",
        arguments: { "arguments" => [ 4796 ] },
        created_at: 3.minutes.ago
      )
      other_class = solid_queue_job(
        class_name: "PollMergeStateJob",
        queue_name: "polling",
        arguments: { "arguments" => [ 4795 ] },
        created_at: 2.minutes.ago
      )
      non_polling = solid_queue_job(
        class_name: "PollPullRequestJob",
        queue_name: "control_plane",
        arguments: { "arguments" => [ 4795 ] },
        created_at: 1.minute.ago
      )

      job = described_class.new
      allow(job).to receive(:prune_finished_jobs)
      allow(job).to receive(:prune_obsolete_ready_jobs)
      allow(job).to receive(:prune_duplicate_workflow_phase_admission_jobs)

      job.perform

      expect(SolidQueue::Job.where(id: [ keep_pr.id, other_pr.id, other_class.id, non_polling.id ]).pluck(:id))
        .to contain_exactly(keep_pr.id, other_pr.id, other_class.id, non_polling.id)
      expect(SolidQueue::Job.where(id: duplicate_pr.id)).to be_empty
      expect(SolidQueue::ReadyExecution.where(job_id: duplicate_pr.id)).to be_empty
    end
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  describe "orphaned job rows" do
    # A job row with no execution row of any kind is reachable by nothing: no
    # worker claims it, and the finished-job pruner skips it because it never
    # finished. 553,671 of these accumulated in production -- 83% of a table
    # every dispatcher scan reads.
    it "deletes unfinished job rows that have no execution row" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!

      orphan = solid_queue_job_without_execution(created_at: 2.days.ago)
      backed = solid_queue_job(
        class_name: "PollPullRequestJob", queue_name: "polling",
        arguments: { "arguments" => [ 1 ] }, created_at: 2.days.ago
      )

      run_only_orphan_sweep

      expect(SolidQueue::Job.where(id: orphan.id)).to be_empty
      expect(SolidQueue::Job.where(id: backed.id)).to be_present,
        "a row with a ready execution is live work, not an orphan"
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    # Enqueue is not always one transaction, so a job row can briefly exist
    # with no execution row yet. Deleting those would drop work that was about
    # to run.
    it "leaves a recently created row alone, in case its execution is still on its way" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!

      fresh = solid_queue_job_without_execution(created_at: 5.minutes.ago)

      run_only_orphan_sweep

      expect(SolidQueue::Job.where(id: fresh.id)).to be_present
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    # Walking by id cursor rather than re-filtering from the start each batch
    # is what keeps a run of live rows from stalling the sweep on them.
    it "gets past live rows to reach orphans behind them" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!

      live = Array.new(3) do |i|
        solid_queue_job(
          class_name: "PollPullRequestJob", queue_name: "polling",
          arguments: { "arguments" => [ i ] }, created_at: 2.days.ago
        )
      end
      orphan = solid_queue_job_without_execution(created_at: 2.days.ago)

      stub_const("#{described_class}::ORPHAN_BATCH_SIZE", 2)
      run_only_orphan_sweep

      expect(SolidQueue::Job.where(id: orphan.id)).to be_empty
      expect(SolidQueue::Job.where(id: live.map(&:id)).count).to eq(3)
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end
  end

  describe "ready executions stranded on a dead resume queue" do
    # The queue names a worker's storage key. Once that storage is gone nothing
    # advertises the queue, so the row can never be claimed -- and while it sits
    # there it pins syrus_global_queue_oldest_age_seconds, the headline "is
    # Syrus keeping up" number, at an age that only grows. One dead row had the
    # dashboard reporting a 31-hour backlog that did not exist.
    it "deletes a terminal Run's row when no live worker serves its queue" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      dead = "resume-58e4be51-b732-47b8-801b-d5260ae10d6e"
      allow(InstanceVersion).to receive(:worker_queue_live?).with(dead).and_return(false)

      failed_run = run
      failed_run.update!(state: "failed")
      stranded = solid_queue_job(
        class_name: "RunJob", queue_name: dead,
        arguments: { "arguments" => [ failed_run.id ] }, created_at: 2.hours.ago
      )

      run_only_dead_resume_sweep

      expect(SolidQueue::Job.where(id: stranded.id)).to be_empty
      expect(SolidQueue::ReadyExecution.where(job_id: stranded.id)).to be_empty
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    # WorkEngine::Reconciler owns the queued case -- it re-enqueues the Run onto
    # a live queue. Deleting the row here would race it and strand real work.
    it "leaves a still-queued Run's row for the reconciler to re-enqueue" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      dead = "resume-58e4be51-b732-47b8-801b-d5260ae10d6e"
      allow(InstanceVersion).to receive(:worker_queue_live?).with(dead).and_return(false)

      queued_run = run
      stranded = solid_queue_job(
        class_name: "RunJob", queue_name: dead,
        arguments: { "arguments" => [ queued_run.id ] }, created_at: 2.hours.ago
      )

      run_only_dead_resume_sweep

      expect(SolidQueue::Job.where(id: stranded.id)).to be_present
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "leaves rows alone while a live worker still serves the queue" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      live = "resume-1b51ff34-d5d2-43ef-94d4-aa4b2440b9c5"
      allow(InstanceVersion).to receive(:worker_queue_live?).with(live).and_return(true)

      failed_run = run
      failed_run.update!(state: "failed")
      kept = solid_queue_job(
        class_name: "RunJob", queue_name: live,
        arguments: { "arguments" => [ failed_run.id ] }, created_at: 2.hours.ago
      )

      run_only_dead_resume_sweep

      expect(SolidQueue::Job.where(id: kept.id)).to be_present
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "deletes a chat relay refresh after the chat moves to another storage queue" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      dead = "resume-old-storage"
      allow(InstanceVersion).to receive(:worker_queue_live?).with(dead).and_return(false)
      chat = ChatSession.create!(user: user, workspace_storage_key: "current-storage")
      stranded = solid_queue_job(
        class_name: "ChatCodingRelayRefreshJob", queue_name: dead,
        arguments: { "arguments" => [ chat.id ] }, created_at: 2.hours.ago
      )

      run_only_dead_resume_sweep

      expect(SolidQueue::Job.where(id: stranded.id)).to be_empty
      expect(SolidQueue::ReadyExecution.where(job_id: stranded.id)).to be_empty
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "keeps a chat relay refresh while the chat still owns the dead storage queue" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      dead = "resume-current-storage"
      allow(InstanceVersion).to receive(:worker_queue_live?).with(dead).and_return(false)
      chat = ChatSession.create!(user: user, workspace_storage_key: "current-storage")
      kept = solid_queue_job(
        class_name: "ChatCodingRelayRefreshJob", queue_name: dead,
        arguments: { "arguments" => [ chat.id ] }, created_at: 2.hours.ago
      )

      run_only_dead_resume_sweep

      expect(SolidQueue::Job.where(id: kept.id)).to be_present
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end
  end

  it "runs frequently enough to spread cleanup work" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(config.fetch("production").fetch("clear_solid_queue_finished_jobs")).to include(
      "class" => "SolidQueueCleanupJob",
      "queue" => "cleanup",
      "schedule" => "every 5 minutes"
    )
  end

  def run_only_orphan_sweep
    job = described_class.new
    %i[prune_finished_jobs prune_obsolete_ready_jobs prune_dead_resume_ready_executions
       prune_duplicate_workflow_phase_admission_jobs prune_duplicate_polling_jobs].each do |method|
      allow(job).to receive(method)
    end
    allow(job).to receive(:sleep)
    job.perform
  end

  def run_only_dead_resume_sweep
    job = described_class.new
    %i[prune_finished_jobs prune_obsolete_ready_jobs prune_orphaned_jobs
       prune_duplicate_workflow_phase_admission_jobs prune_duplicate_polling_jobs].each do |method|
      allow(job).to receive(method)
    end
    allow(job).to receive(:sleep)
    job.perform
  end

  # The absence of an execution row is what makes a job row an orphan, and
  # Solid Queue will not let you create one directly -- SolidQueue::Job creates
  # its ready execution on create. Which is the point: orphans do not come from
  # enqueueing, they come from an execution row being deleted out from under a
  # job row, so the fixture reproduces that rather than a state the writer path
  # can reach.
  def solid_queue_job_without_execution(created_at:, class_name: "IndexTestCaseSearchJob", queue_name: "indexing")
    job = SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: { "arguments" => [ 1 ] },
      created_at: created_at,
      updated_at: created_at
    )
    SolidQueue::ReadyExecution.where(job_id: job.id).delete_all
    SolidQueue::ScheduledExecution.where(job_id: job.id).delete_all
    job
  end

  def solid_queue_job(arguments:, created_at:, class_name: "WorkflowPhaseAdmissionJob", queue_name: "control_plane")
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: arguments,
      created_at: created_at,
      updated_at: created_at
    ).tap do |job|
      SolidQueue::ReadyExecution.create!(
        job_id: job.id,
        queue_name: queue_name,
        priority: 0,
        created_at: created_at
      )
    end
  end
end
