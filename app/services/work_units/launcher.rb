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

    Result = Data.define(:workflow, :run, :intent, :work_unit, :status, :reason, :gate_result) do
      def started? = status == "started"
      def blocked? = status == "blocked"
    end

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

    def self.instantiate_intent!(intent, artifacts: nil, agent_provider: nil, **options)
      relaunch_context = relaunch_context_for_intent!(intent)
      artifacts = relaunch_artifacts_for(intent, artifacts)
      new(
        kind: intent.kind,
        job: relaunch_context.job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        idempotency_key: intent.idempotency_key,
        source_type: intent.source_type.presence || "work_intent_relaunch",
        source_id: intent.source_id,
        options: options.merge(member_jobs: relaunch_context.member_jobs),
        existing_intent: intent
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
      unit = workflow.work_unit
      ensure_landing_job_state!(workflow, unit)
      if unit
        gate_result = Scheduler.evaluate!(unit)
        if gate_result.blocked?
          schedule_blocked_recheck!(workflow, gate_result)
          return Result.new(
            workflow: workflow,
            run: nil,
            intent: unit.work_intent,
            work_unit: unit,
            status: "blocked",
            reason: gate_result.reason,
            gate_result: gate_result
          )
        end
      end

      run = StepDispatcher.start_workflow(workflow, **options)
      Result.new(
        workflow: workflow,
        run: run,
        intent: unit&.work_intent,
        work_unit: unit,
        status: run ? "started" : "not_started",
        reason: nil,
        gate_result: nil
      )
    end

    def self.schedule_blocked_recheck!(workflow, gate_result)
      return if gate_result.reason == WorkUnits::Gates::ManualPause::REASON

      wait_until = gate_result.retry_at
      priority = workflow.job.solid_queue_priority
      if wait_until&.future?
        WorkflowPhaseAdmissionJob.enqueue_once(workflow.id, wait_until: wait_until, priority: priority)
      else
        WorkflowPhaseAdmissionJob.enqueue_once(workflow.id, wait: StepDispatcher::START_BLOCKED_BACKOFF, priority: priority)
      end

      return unless workflow.landing_workflow?

      LandingQueueProcessorJob.set(wait: landing_recheck_delay(wait_until), priority: priority).perform_later
    end

    def self.landing_recheck_delay(wait_until)
      return StepDispatcher::START_BLOCKED_BACKOFF unless wait_until&.future?

      [ wait_until - Time.current, StepDispatcher::START_BLOCKED_BACKOFF.to_i ].max.seconds
    end

    def self.ensure_landing_job_state!(workflow, unit)
      return unless workflow.landing_workflow?
      return unless unit&.definition&.first_class?
      return unless unit.definition.scope == "job"

      LandingWorkJobState.ensure_landing!(
        job: workflow.job,
        workflow: workflow,
        reason: "landing_work_start"
      )
    end

    RelaunchContext = Data.define(:job, :member_jobs)

    def self.relaunch_context_for_intent!(intent)
      previous_unit = intent.work_units.includes(:workflow, work_unit_members: :job).order(created_at: :desc, id: :desc).first
      previous_workflow = previous_unit&.workflow
      snapshot_members = previous_unit&.work_unit_members&.sort_by(&:id)&.map(&:job)&.compact || []

      job = previous_workflow&.job || representative_job_for_intent(intent, snapshot_members)
      unless job
        raise ArgumentError, "cannot instantiate WorkIntent ##{intent.id}: no representative job for #{intent.scope_type.inspect} scope"
      end

      RelaunchContext.new(job: job, member_jobs: snapshot_members.presence)
    end

    def self.relaunch_artifacts_for(intent, artifacts)
      return artifacts if artifacts

      intent.payload_artifacts.presence || {}
    end

    def self.representative_job_for_intent(intent, snapshot_members)
      WorkIntentScope.for(intent.scope_type).representative_job(
        scope_id: intent.scope_id,
        repository_id: intent.repository_id,
        snapshot_members: snapshot_members
      )
    end

    def initialize(kind:, job:, artifacts:, agent_provider:, idempotency_key:, source_type:, source_id:, options:, existing_intent: nil)
      @definition = WorkDefinitions.for(kind)
      @job = job
      @artifacts = artifacts
      @agent_provider = agent_provider
      @idempotency_key = idempotency_key
      @source_type = source_type
      @source_id = source_id
      @options = options
      @member_jobs_override = Array(@options.delete(:member_jobs)).presence
      @parent_work_unit = @options.delete(:parent_work_unit)
      @existing_intent = existing_intent
      @scope = @definition.scope_for(job: job, artifacts: payload_artifacts, **options)
      @member_jobs = @member_jobs_override || @definition.members_for(job: job, artifacts: payload_artifacts, **options)
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
        preempt_superseded_ci_repairs!(unit) if definition.preempts_ci_failure?
        workflow
      end
    end

    private

    attr_reader :definition, :job, :agent_provider, :idempotency_key, :source_type, :source_id, :options, :ref_metadata, :existing_intent, :parent_work_unit

    def find_or_create_intent!
      if existing_intent
        persist_payload_artifacts!(existing_intent)
        return existing_intent
      end
      return WorkIntent.create!(intent_attributes) if idempotency_key.blank?

      WorkIntent.find_or_create_by!(idempotency_key: idempotency_key) do |intent|
        intent.assign_attributes(intent_attributes)
      end.tap { |intent| persist_payload_artifacts!(intent) }
    end

    def persist_payload_artifacts!(intent)
      artifacts = payload_artifacts
      return if artifacts.blank?
      return if intent.payload_artifacts == artifacts

      intent.update!(payload_artifacts: artifacts)
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
        source_id: source_id,
        payload_artifacts: payload_artifacts
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
        parent_work_unit: parent_work_unit,
        **unit_ref_metadata_attributes(intent)
      )
    end

    def unit_ref_metadata_attributes(intent)
      return ref_metadata.attributes unless existing_intent

      ref_metadata.attributes.merge(
        delivery_track: intent.delivery_track,
        source_repository: intent.source_repository,
        source_remote_kind: intent.source_remote_kind,
        source_ref: intent.source_ref,
        target_repository: intent.target_repository,
        target_remote_kind: intent.target_remote_kind,
        target_ref: intent.target_ref
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
        create_lock!(unit, lock_key)
      end
    end

    def create_lock!(unit, lock_key)
      if (owner = Ownership.active_unit_for_lock_key(lock_key))
        raise LockConflict.new(lock_key: lock_key, work_unit: owner) if definition.landing_lock?

        return
      end

      unit.work_unit_locks.create!(lock_key: lock_key)
    rescue ActiveRecord::RecordNotUnique
      owner = Ownership.active_unit_for_lock_key(lock_key)
      raise LockConflict.new(lock_key: lock_key, work_unit: owner) if owner && definition.landing_lock?
    end

    def preempt_superseded_ci_repairs!(unit)
      member_jobs.each do |member_job|
        active_ci_repair_units_for(member_job, excluding: unit).each do |ci_unit|
          next unless ci_unit.workflow

          WorkUnits::WorkflowCancellation.cancel!(
            ci_unit.workflow,
            reason: "superseded_by_rebase",
            artifacts: {
              "cancelled_reason" => Workflow::SUPERSEDED_BY_REBASE_REASON,
              "preempted_by_work_unit_id" => unit.id,
              "preempted_by_workflow_id" => unit.workflow_id,
              "preemption_reason" => "superseded_by_rebase"
            },
            by_work_unit: unit
          )
        end
      end
    end

    def active_ci_repair_units_for(member_job, excluding:)
      WorkUnit
        .joins(:work_unit_members)
        .where(work_unit_members: { job_id: member_job.id })
        .where(kind: "ci_failure", state: %w[queued blocked running])
        .where.not(id: excluding.id)
        .includes(:workflow)
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
