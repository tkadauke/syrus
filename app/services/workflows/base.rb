module Workflows
  # Base class for v1 workflow templates. A subclass declares its chain
  # with plain step kinds and optional Workflows::Loop nodes; `instantiate(job:)`
  # creates the Workflow + the initial Step rows with `next_step_id`
  # wiring + position numbers, returns the Workflow.
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
    # Loops are allowed as top-level nodes only:
    #   steps :prepare,
    #         Workflows::Loop.new(max_iterations: 5, steps: [:implement, :grade]),
    #         :summarize
    def self.steps(*kinds)
      self.step_kinds = normalize_chain_template(kinds).freeze
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
      chain_template = steps_for(job)
      raise "no steps declared for #{name}" if chain_template.nil? || chain_template.empty?

      effective_artifacts = artifacts
      effective_chain_template = chain_template
      if (skip_reason = job.prepare_skip_reason)
        effective_chain_template = effective_chain_template.reject { |node| node == "prepare" }
        effective_artifacts = (effective_artifacts || {}).merge(
          "prepare_skipped" => true,
          "prepare_skipped_reason" => skip_reason
        )
      end

      Workflow.transaction do
        wf = Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          agent_provider: agent_provider || job.agent_provider || job.user.agent_provider,
          chain_template: serialize_chain_template(effective_chain_template),
          artifacts: effective_artifacts
        )
        steps = materialize_steps!(wf, effective_chain_template)
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

    def self.normalize_chain_template(nodes)
      nodes.map do |node|
        case node
        when Workflows::Loop
          validate_loop!(node)
          node
        when Symbol, String
          node.to_s
        else
          raise ArgumentError,
                "workflow steps must be symbols, strings, or Workflows::Loop instances; got #{node.inspect}"
        end
      end
    end

    def self.validate_loop!(loop)
      nested = loop.steps.any? { |step| step.is_a?(Workflows::Loop) }
      raise ArgumentError, "nested Workflows::Loop nodes are not supported" if nested
    end

    def self.serialize_chain_template(nodes)
      nodes.map do |node|
        if node.is_a?(Workflows::Loop)
          node.to_chain_template
        else
          { "type" => "step", "kind" => node.to_s }
        end
      end
    end

    def self.materialize_steps!(workflow, nodes)
      position = 0
      nodes.flat_map do |node|
        if node.is_a?(Workflows::Loop)
          loop_id = SecureRandom.uuid
          node.step_kinds.map do |kind|
            step = Step.create!(
              workflow: workflow,
              kind: kind,
              position: position,
              iteration: 1,
              loop_id: loop_id
            )
            position += 1
            step
          end
        else
          step = Step.create!(
            workflow: workflow,
            kind: node.to_s,
            position: position,
            iteration: 1
          )
          position += 1
          step
        end
      end
    end
  end
end
