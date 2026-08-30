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
    # Workflows::Try failure branch may declare its own recovery segment
    # with RetryUntil/Loop/Try nodes:
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

    # `workflow.priority` overrides `job.priority` for this workflow's
    # dispatch when it has been explicitly set away from the default
    # (e.g. a low-priority deferred workflow that should queue behind
    # the job's own work). Workflows that never touch their own
    # `priority` column stay on `job.solid_queue_priority` unchanged.
    def self.solid_queue_priority(workflow)
      job = workflow.job
      return job.solid_queue_priority if workflow.priority == Workflow::DEFAULT_PRIORITY

      Job::PRIORITY_TO_SQ.fetch(workflow.priority, job.solid_queue_priority)
    end

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

    def self.prepare_then(job, *nodes)
      chain = [ "prepare", *nodes.flatten ].compact
      without_skipped_prepare(job, chain)
    end

    def self.without_skipped_prepare(job, chain)
      prepare_skipped_for?(job) ? chain.reject { |node| node == "prepare" } : chain
    end

    # `review_first:` models a loop whose iteration 1 reviews work an
    # `agent_step` already produced outside the loop (see Workflows::Loop),
    # rather than pairing a fresh agent_step with the review on every
    # iteration. Only Initial uses this today: its top-level `implement`
    # step runs unconditionally before this loop is ever consulted, so
    # iteration 1 has something to review already. Other call sites (whose
    # agent_step only ever runs inside this loop) keep the default.
    def self.adversarial_review_loop(job, agent_step:, review_first: false)
      rounds = adversarial_review_rounds(job)
      return nil unless rounds.positive?

      Workflows::Loop.new(max_iterations: rounds, steps: [ agent_step, :adversarial_review ], review_first: review_first)
    end

    def self.visual_review_loop(job, agent_step:)
      plan = RepoVisualReviewPlan.for_job(job)
      return nil unless plan.enabled? && plan.rounds.positive?

      Workflows::Loop.new(max_iterations: plan.rounds, steps: [ agent_step, :visual_review ])
    end

    # `autofix:` inserts the config-driven format (rubocop -a, eslint --fix,
    # gofmt -w, ... or `.syrus.yml` `formatters:`) and generate (`.syrus.yml`
    # `generated:`) steps between the agent step and the grader check on
    # every iteration, so a style-only failure or stale generated output the
    # fixer could resolve for free never costs the agent a turn. Opt-in per
    # call site rather than unconditional so ci_failure/skill/
    # main_branch_repair/external_pr_feedback (repair loops with different
    # repair semantics) aren't affected by a change scoped to
    # initial/retry/pr_comment/chat_feedback.
    #
    # For those autofix call sites, format/generate/grader Steps are only
    # materialized when the repository's `.syrus.yml` actually configures
    # them (RepoGradeLoopPlan, read pre-clone the same way
    # RepoAdversarialReviewPlan/RepoVisualReviewPlan are) — none of the
    # three is configured by default, so a freshly onboarded repo with no
    # `.syrus.yml` yet gets a bare agent step with no grade loop at all. As
    # soon as any one of them is configured, the whole grade loop (the agent
    # step, whichever of format/generate are configured, and
    # grader_fanout/grader_collect together) is materialized.
    #
    # `repair_first:` (default true) mirrors Workflows::RetryUntil#repair_first:
    # the agent_step runs on every iteration including the first. Only
    # Initial passes `repair_first: false` — its top-level `implement` step
    # already ran before this loop, so the first grading pass should run the
    # non-implement pipeline (format/generate/graders) directly against
    # that work; agent_step is only added back in as a repair once a grader
    # fails. Other call sites have no guaranteed agent step before this loop
    # (e.g. PrFeedback's `respond` may only ever run here), so they keep
    # agent_step on iteration 1.
    def self.grader_retry_loop(job, agent_step, max_iterations: AppSetting.grade_max_iterations, autofix: false, repair_first: true)
      return unconditional_grader_retry_loop(agent_step, max_iterations: max_iterations) unless autofix

      plan = RepoGradeLoopPlan.for_job(job)
      return (repair_first ? agent_step : nil) unless plan.any_configured?

      autofix_steps = []
      autofix_steps << :format if plan.format_configured
      autofix_steps << :generate if plan.generate_configured

      repair, check =
        if repair_first
          [ [ agent_step ] + autofix_steps, [ :grader_fanout, :grader_collect ] ]
        else
          [ [ agent_step ], autofix_steps + [ :grader_fanout, :grader_collect ] ]
        end

      Workflows::RetryUntil.new(max_iterations: max_iterations, repair_first: repair_first, repair: repair, check: check)
    end

    def self.unconditional_grader_retry_loop(agent_step, max_iterations:)
      Workflows::RetryUntil.new(
        max_iterations: max_iterations,
        repair: [ agent_step ],
        check: [ :grader_fanout, :grader_collect ]
      )
    end

    def self.landing_grader_retry_loop(max_iterations: AppSetting.grade_max_iterations)
      Workflows::RetryUntil.new(
        max_iterations: max_iterations,
        repair_first: false,
        repair: [ :landing_fix ],
        check: [ :grader_fanout, :grader_collect ]
      )
    end

    def self.grader_gate_steps
      [ "grader_fanout", "grader_collect" ]
    end

    def self.initial_pr_finish_steps
      [ "summarize", "test_plan", "pr_open", "review_plan" ]
    end

    def self.feedback_finish_steps
      [
        "coverage_analyze",
        "coverage_pr_comment",
        "dependency_audit",
        "dependency_audit_pr_comment",
        "summarize_amend",
        "refresh_job_metadata",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      ]
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
          landing_grader_retry_loop(max_iterations: max_iterations),
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
          branch.each { |branch_node| validate_control_node!(branch_node) if branch_node.respond_to?(:to_chain_template) }
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
          step = materialize_try_step!(workflow, node, position)
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

    def self.materialize_try_step!(workflow, node, position)
      Step.create!(
        workflow: workflow,
        kind: node.step_kind,
        position: position,
        iteration: 1,
        details: { "try_id" => node.id }
      )
    end
  end
end
