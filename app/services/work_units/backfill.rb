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
        intent.assign_attributes(ref_metadata.attributes)
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
        finished_at: workflow.finished_at,
        **ref_metadata.attributes
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
      definition.lock_keys_for(job: job, member_jobs: member_jobs, artifacts: workflow.artifacts.to_h).each do |lock_key|
        unit.work_unit_locks.create!(lock_key: lock_key)
      end
    end

    def member_jobs
      @member_jobs ||= definition.members_for(job: job, artifacts: workflow.artifacts.to_h)
    end

    def scope_type
      scope.type
    end

    def scope_id
      scope.id
    end

    def scope
      @scope ||= definition.scope_for(job: job, artifacts: workflow.artifacts.to_h)
    end

    def ref_metadata
      @ref_metadata ||= definition.ref_metadata_for(job: job, artifacts: workflow.artifacts.to_h)
    end

    def idempotency_key
      "#{WORKFLOW_IDEMPOTENCY_PREFIX}#{workflow.id}"
    end
  end
end
