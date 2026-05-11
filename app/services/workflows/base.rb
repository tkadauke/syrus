module Workflows
  # Base class for v1 linear-chain workflow templates. A subclass
  # declares its step kinds via the `STEPS` constant in execution
  # order; `instantiate(job:)` creates the Workflow + the chain of
  # Steps with `next_step_id` wiring + position numbers, returns the
  # Workflow.
  #
  # The workflow starts in `queued` state with the first step also
  # `queued`. Whoever instantiates is responsible for calling
  # StepDispatcher.advance_from (or kicking off the first Run
  # directly) once they're ready for execution to begin — the
  # template doesn't auto-start so creation can happen inside a
  # transaction without firing background jobs prematurely.
  class Base
    class << self
      attr_accessor :step_kinds
    end

    # Subclasses use this DSL to declare their chain:
    #   class Initial < Base
    #     steps :implement, :summarize, :pr_open
    #   end
    def self.steps(*kinds)
      self.step_kinds = kinds.map(&:to_s).freeze
    end

    def self.trigger_kind
      raise NotImplementedError, "#{name} must define `trigger_kind`"
    end

    # Build the Workflow + Steps for the given job. Returns the
    # persisted Workflow with its steps. `artifacts` seeds the
    # workflow with structured input that downstream step handlers
    # read — PrFeedback wants `pr_comments`, CiFailure wants
    # `failed_checks` + `head_sha`. Handlers compose their prompts
    # from these at run time, so the polling job (or controller)
    # doesn't need to know prompt internals.
    def self.instantiate(job:, artifacts: nil, agent_provider: nil)
      kinds = steps_for(job)
      raise "no steps declared for #{name}" if kinds.nil? || kinds.empty?

      workflow_artifacts = artifacts
      if prepare_skipped_for?(job)
        workflow_artifacts = (workflow_artifacts || {}).merge("prepare_skipped" => true)
      end

      Workflow.transaction do
        wf = Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          agent_provider: agent_provider || job.agent_provider || job.user.agent_provider,
          artifacts: workflow_artifacts
        )
        steps = kinds.each_with_index.map do |kind, position|
          Step.create!(workflow: wf, kind: kind, position: position)
        end
        # Wire next_step_id top-down so each step points to its
        # successor. Last step's next_step_id stays nil.
        steps.each_cons(2) { |s, nxt| s.update!(next_step_id: nxt.id) }
        wf
      end
    end

    def self.steps_for(_job)
      step_kinds
    end

    def self.prepare_skipped_for?(_job)
      false
    end
  end
end
