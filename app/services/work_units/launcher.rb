module WorkUnits
  class Launcher
    class LockConflict < StandardError
      attr_reader :lock_key, :work_unit

      def initialize(lock_key:, work_unit:)
        @lock_key = lock_key
        @work_unit = work_unit
        super("active WorkUnit ##{work_unit.id} already owns lock #{lock_key}")
      end
    end

    Result = Data.define(:workflow, :run)

    def self.instantiate(kind:, job:, artifacts: nil, agent_provider: nil, idempotency_key: nil, source_type: "workflow_launch", source_id: nil, **options)
      new(
        kind: kind,
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        idempotency_key: idempotency_key,
        source_type: source_type,
        source_id: source_id,
        options: options
      ).instantiate
    end

    def self.create_and_start!(kind:, job:, artifacts: nil, agent_provider: nil, idempotency_key: nil, source_type: "workflow_launch", source_id: nil, before_start: nil, **options)
      workflow = instantiate(
        kind: kind,
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        idempotency_key: idempotency_key,
        source_type: source_type,
        source_id: source_id,
        **options
      )
      before_start&.call(workflow)
      start!(workflow)
    end

    def self.start!(workflow, **options)
      Result.new(workflow: workflow, run: StepDispatcher.start_workflow(workflow, **options))
    end

    def initialize(kind:, job:, artifacts:, agent_provider:, idempotency_key:, source_type:, source_id:, options:)
      @definition = WorkDefinitions.for(kind)
      @job = job
      @artifacts = artifacts
      @agent_provider = agent_provider
      @idempotency_key = idempotency_key
      @source_type = source_type
      @source_id = source_id
      @options = options
      @scope = @definition.scope_for(job: job, artifacts: payload_artifacts, **options)
      @member_jobs = @definition.members_for(job: job, artifacts: payload_artifacts, **options)
      @ref_metadata = @definition.ref_metadata_for(job: job, artifacts: payload_artifacts, **options)
    end

    def instantiate
      WorkIntent.transaction do
        intent = find_or_create_intent!
        if (workflow = active_workflow_for(intent))
          return workflow
        end

        unit = create_unit!(intent)
        workflow = definition.workflow_template.instantiate(**instantiate_arguments)
        unit.update!(workflow: workflow)
        create_members!(unit)
        create_locks!(unit)
        workflow
      end
    end

    private

    attr_reader :definition, :job, :agent_provider, :idempotency_key, :source_type, :source_id, :options, :ref_metadata

    def find_or_create_intent!
      return WorkIntent.create!(intent_attributes) if idempotency_key.blank?

      WorkIntent.find_or_create_by!(idempotency_key: idempotency_key) do |intent|
        intent.assign_attributes(intent_attributes)
      end
    end

    def intent_attributes
      {
        kind: definition.kind,
        state: "requested",
        repository: job.repository,
        scope_type: scope_type,
        scope_id: scope_id,
        priority: job.priority,
        actor: job.user,
        source_type: source_type,
        source_id: source_id
      }.merge(ref_metadata.attributes)
    end

    def active_workflow_for(intent)
      return nil if idempotency_key.blank?

      unit = intent.work_units
        .where(state: %w[queued blocked running])
        .where.not(workflow_id: nil)
        .includes(:workflow)
        .order(created_at: :desc, id: :desc)
        .first
      unit&.workflow
    end

    def create_unit!(intent)
      WorkUnit.create!(
        work_intent: intent,
        kind: definition.kind,
        state: "queued",
        repository: job.repository,
        scope_type: scope_type,
        scope_id: scope_id,
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
      definition.lock_keys_for(job: job, member_jobs: member_jobs, artifacts: payload_artifacts, **options).each do |lock_key|
        if (owner = Ownership.active_unit_for_lock_key(lock_key))
          raise LockConflict.new(lock_key: lock_key, work_unit: owner)
        end

        unit.work_unit_locks.create!(lock_key: lock_key)
      end
    end

    def scope_type
      scope.type
    end

    def scope_id
      scope.id
    end

    def member_jobs
      @member_jobs
    end

    def payload_artifacts
      @artifacts || {}
    end

    def raw_artifacts
      @artifacts
    end

    def instantiate_arguments
      {
        job: job,
        artifacts: raw_artifacts,
        agent_provider: agent_provider
      }.merge(options)
    end

    def scope
      @scope
    end
  end
end
