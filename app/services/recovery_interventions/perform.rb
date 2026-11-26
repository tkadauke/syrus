module RecoveryInterventions
  class Perform
    def self.call(**arguments, &block) = new(**arguments).call(&block)

    def initialize(job:, action:, mode:, actor_type:, actor: nil, actor_display: nil, origin:, reason: nil,
                   guidance: nil, source_workflow: nil)
      @job = job
      @action = action
      @mode = mode
      @actor_type = actor_type
      @actor = actor
      @actor_display = actor_display
      @origin = origin
      @reason = reason
      @guidance = guidance
      @source_workflow = source_workflow
    end

    def call
      decision = RecoveryDecision.for(job: @job, workflow: @source_workflow)
      result = yield
      return result unless result.respond_to?(:success?) && result.success?

      workflow = result.workflow
      return result unless workflow.is_a?(Workflow) && workflow.persisted?

      result_step = result.respond_to?(:step) ? result.step : nil
      step = result_step if result_step.is_a?(Step) && result_step.persisted?
      result_run = result.respond_to?(:run) ? result.run : nil
      run = result_run if result_run.is_a?(Run) && result_run.persisted?
      run ||= step&.latest_run
      source_step = decision.evidence[:source_step_id] && Step.find_by(id: decision.evidence[:source_step_id])
      source_run = decision.evidence[:source_run_id] && Run.find_by(id: decision.evidence[:source_run_id])
      RecoveryIntervention.create!(
        job: @job, source_workflow: @source_workflow, source_step:, source_run:,
        resulting_workflow: workflow, resulting_step: step, resulting_run: run,
        source_loop_id: decision.evidence[:source_loop_id], resulting_loop_id: step&.loop_id,
        actor_type: @actor_type,
        actor_id: @actor&.id, actor_display: @actor_display.presence || actor_label,
        origin: @origin, action: @action, recovery_kind: decision.kind, recovery_mode: @mode,
        reason: @reason, guidance: @guidance, source_revision: decision.evidence[:source_revision],
        resulting_revision: run&.head_sha, failure_classification: decision.evidence[:failure_classification],
        failure_evidence: decision.evidence.deep_stringify_keys, performed_at: Time.current
      )
      result
    end

    private

    def actor_label
      return if @actor.nil?
      return @actor.display_name if @actor.respond_to?(:display_name) && @actor.display_name.present?
      return @actor.name if @actor.respond_to?(:name) && @actor.name.present?

      @actor.to_s
    end
  end
end
