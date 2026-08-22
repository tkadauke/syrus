module WorkUnits
  class Backfill
    Result = Data.define(:workflow, :work_unit, :created, :skipped_reason) do
      def created? = created
      def skipped? = skipped_reason.present?
    end

    ACTIVE_STATES = %w[queued running].freeze
    WORKFLOW_IDEMPOTENCY_PREFIX = "workflow:".freeze

    def self.active!(limit: nil)
      scope = Workflow.left_outer_joins(:work_unit).where(state: ACTIVE_STATES, work_units: { id: nil }).order(:created_at, :id)
      scope = scope.limit(limit) if limit
      scope.find_each.map { |workflow| workflow!(workflow) }
    end

    def self.workflow!(workflow)
      new(workflow).call
    end

    def initialize(workflow)
      @workflow = workflow
      @job = workflow.job
    end

    def call
      return Result.new(workflow: workflow, work_unit: workflow.work_unit, created: false, skipped_reason: "already_backfilled") if workflow.work_unit
      return Result.new(workflow: workflow, work_unit: nil, created: false, skipped_reason: "missing_job") unless job
      return Result.new(workflow: workflow, work_unit: nil, created: false, skipped_reason: "unknown_work_definition") unless definition

      WorkUnit.transaction do
        intent = find_or_create_intent!
        unit = create_unit!(intent)
        create_members!(unit)
        create_locks!(unit)
        Result.new(workflow: workflow, work_unit: unit, created: true, skipped_reason: nil)
      end
    end

    private

    attr_reader :workflow, :job

    def definition
      @definition ||= begin
        WorkDefinitions.for(workflow.trigger_kind)
      rescue WorkDefinitions::UnknownKind
        nil
      end
    end

    def find_or_create_intent!
      WorkIntent.find_or_create_by!(idempotency_key: idempotency_key) do |intent|
        intent.kind = definition.kind
        intent.state = "requested"
        intent.repository = job.repository
        intent.scope_type = scope_type
        intent.scope_id = scope_id
        intent.priority = job.priority
        intent.actor = job.user
        intent.source_type = "workflow_backfill"
        intent.source_id = workflow.id
        intent.requested_at = workflow.created_at || Time.current
      end
    end

    def create_unit!(intent)
      WorkUnit.create!(
        work_intent: intent,
        kind: definition.kind,
        state: workflow.state,
        repository: job.repository,
        scope_type: scope_type,
        scope_id: scope_id,
        workflow: workflow,
        started_at: workflow.started_at,
        finished_at: workflow.finished_at
      )
    end

    def create_members!(unit)
      member_jobs.each_with_index do |member_job, index|
        unit.work_unit_members.create!(
          job: member_job,
          role: index.zero? ? "primary" : "member"
        )
      end
    end

    def create_locks!(unit)
      definition.lock_keys_for(job: job, member_jobs: member_jobs).each do |lock_key|
        unit.work_unit_locks.create!(lock_key: lock_key)
      end
    end

    def member_jobs
      @member_jobs ||= merge_train_member_jobs.presence ||
        prefetch_merge_train_member_jobs.presence ||
        [ job ]
    end

    def merge_train_member_jobs
      return [] unless definition.kind == "merge_train"

      train_id = workflow.artifact("merge_train_id")
      return [] if train_id.blank?

      train = MergeTrain.includes(members: :job).find_by(id: train_id)
      return [] unless train

      train.members.sort_by(&:position).map(&:job)
    end

    def prefetch_merge_train_member_jobs
      return [] unless definition.kind == "merge_train_validation"

      ids = Array(workflow.artifact("prefetch_merge_train_member_job_ids")).map(&:to_i).select(&:positive?)
      return [] if ids.blank?

      jobs_by_id = Job.where(id: ids).index_by(&:id)
      ids.filter_map { |id| jobs_by_id[id] }
    end

    def scope_type
      definition.scope.presence || "job"
    end

    def scope_id
      case scope_type
      when "job"
        job.id
      when "epic"
        job.epic_id
      when "repository"
        job.repository_id
      else
        job.id
      end
    end

    def idempotency_key
      "#{WORKFLOW_IDEMPOTENCY_PREFIX}#{workflow.id}"
    end
  end
end
