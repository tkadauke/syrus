module WorkUnits
  class Launcher
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

    def initialize(kind:, job:, artifacts:, agent_provider:, idempotency_key:, source_type:, source_id:, options:)
      @definition = WorkDefinitions.for(kind)
      @job = job
      @artifacts = artifacts
      @agent_provider = agent_provider
      @idempotency_key = idempotency_key
      @source_type = source_type
      @source_id = source_id
      @options = options
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

    attr_reader :definition, :job, :agent_provider, :idempotency_key, :source_type, :source_id, :options

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
      }
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
        scope_id: scope_id
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

    def scope_type
      definition.scope
    end

    def scope_id
      case definition.scope
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

    def member_jobs
      merge_train_member_jobs.presence ||
        prefetch_merge_train_member_jobs.presence ||
        [ job ]
    end

    def merge_train_member_jobs
      return [] unless definition.kind == "merge_train"

      train_id = payload_artifacts["merge_train_id"]
      return [] if train_id.blank?

      train = MergeTrain.includes(:members).find_by(id: train_id)
      return [] unless train

      train.members.includes(:job).order(:position).map(&:job)
    end

    def prefetch_merge_train_member_jobs
      return [] unless definition.kind == "merge_train_validation"

      ids = Array(payload_artifacts["prefetch_merge_train_member_job_ids"]).map(&:to_i).select(&:positive?)
      return [] if ids.blank?

      jobs_by_id = Job.where(id: ids).index_by(&:id)
      ids.filter_map { |id| jobs_by_id[id] }
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
  end
end
