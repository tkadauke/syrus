module Workflows
  # Base class for v1 workflow templates. A subclass declares its chain
  # with plain step kinds and optional workflow control nodes; `instantiate(job:)`
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
    # Control nodes are allowed as top-level nodes only, except that a
    # Workflows::Try failure branch may declare its own RetryUntil/Loop
    # recovery segment:
    #   steps :prepare,
    #         Workflows::Loop.new(max_iterations: 5, steps: [:implement, :grade]),
    #         :summarize
    def self.steps(*kinds)
      self.step_kinds = normalize_chain_template(kinds).freeze
    end

    def self.trigger_kind
      raise NotImplementedError, "#{name} must define `trigger_kind`"
    end

    def self.agentic? = true

    def self.queue_name = :runs

    # Lifecycle hooks. The Workflow model invokes the matching hook
    # on the workflow-template class via Workflow#dispatch_hook after
    # the model handles generic concerns (timestamps, workspace
    # cleanup). Hooks receive the Workflow model instance.
    #
    # Subclasses override what they care about — e.g. PrFeedback marks
    # feedback as addressed in after_success, Rebase re-dispatches
    # auto-merge after a successful rebase. Defaults are no-ops so
    # adding a new template doesn't require declaring stubs.
    #
    # Exceptions raised here are caught and logged by
    # Workflow#dispatch_hook — a hook failure must NOT roll back the
    # state transition that already happened.
    def self.after_success(workflow); end
    def self.after_fail(workflow); end
    def self.after_cancel(workflow); end

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
          agent_provider: agent_provider.presence || job.workflow_agent_provider || job.agent_provider || job.user.agent_provider,
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

    def self.prepare_skipped_for?(job)
      job.skip_prepare?
    end

    def self.coverage_analyze_for(job)
      "coverage_analyze" if RepoCoveragePlanReader.for_job(job)
    end

    def self.adversarial_review_rounds(job)
      plan = RepoAdversarialReviewPlan.for_job(job)
      return plan.rounds if plan.enabled?
      return plan.rounds if plan.source == ".syrus.yml" && plan.note.nil?

      AppSetting.adversarial_review_rounds
    end

    def self.follow_up_push(max_iterations: nil)
      Workflows::Try.new(:push).on_failure(
        "remote_branch_advanced_rebase_conflict",
        [
          :push_agent_rebase,
          Workflows::RetryUntil.new(
            max_iterations: max_iterations,
            repair_first: false,
            repair: [ :landing_fix ],
            check: [ :grader_fanout, :grader_collect ]
          ),
          :push_after_rebase
        ]
      )
    end

    def self.normalize_chain_template(nodes)
      nodes.map do |node|
        case node
        when Workflows::Loop, Workflows::RetryUntil, Workflows::Try
          validate_control_node!(node)
          node
        when Symbol, String
          node.to_s
        else
          raise ArgumentError,
                "workflow steps must be symbols, strings, or workflow control nodes; got #{node.inspect}"
        end
      end
    end

    def self.validate_control_node!(node)
      if node.is_a?(Workflows::Try)
        node.failure_branches.each_value do |branch|
          branch.each do |branch_node|
            if branch_node.is_a?(Workflows::Try)
              raise ArgumentError, "nested workflow try nodes are not supported"
            end

            validate_control_node!(branch_node) if branch_node.is_a?(Workflows::Loop) || branch_node.is_a?(Workflows::RetryUntil)
          end
        end
      else
        nested = control_node_steps(node).any? do |step|
          step.is_a?(Workflows::Loop) || step.is_a?(Workflows::RetryUntil) || step.is_a?(Workflows::Try)
        end
        raise ArgumentError, "nested workflow control nodes are not supported" if nested
      end
    end

    def self.control_node_steps(node)
      case node
      when Workflows::Loop
        node.steps
      when Workflows::RetryUntil
        node.repair_steps + node.check_steps
      when Workflows::Try
        [ node.step_kind ] + node.failure_branches.values.flatten
      else
        []
      end
    end

    def self.serialize_chain_template(nodes)
      nodes.map do |node|
        if node.is_a?(Workflows::Loop) || node.is_a?(Workflows::RetryUntil) || node.is_a?(Workflows::Try)
          node.to_chain_template
        else
          { "type" => "step", "kind" => node.to_s }
        end
      end
    end

    def self.materialize_steps!(workflow, nodes)
      position = 0
      nodes.flat_map do |node|
        if node.is_a?(Workflows::Try)
          step = Step.create!(
            workflow: workflow,
            kind: node.step_kind,
            position: position,
            iteration: 1,
            details: { "try_id" => node.id }
          )
          position += 1
          step
        elsif node.is_a?(Workflows::Loop) || node.is_a?(Workflows::RetryUntil)
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
