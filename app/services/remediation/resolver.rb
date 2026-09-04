class Remediation
  # The one resolution rule (workflow-engine-v3 primitive B):
  #
  #   step override -> template override -> work-definition policy -> problem default
  #
  # Seeded to reproduce exactly what the existing mechanisms already decide.
  # The tiers are not new policy; they are the precedence that was previously
  # implicit in which of five mechanisms happened to be consulted first.
  #
  # Tiers 1 and 2 have no producers yet -- nothing writes a step or template
  # override today -- so every current decision comes from tier 3 or 4. They
  # exist now because the order is the contract; adding a producer later must
  # not also mean deciding where it sits.
  class Resolver
    def self.call(...) = new(...).call

    # `problem`   -- the Problem being remediated, if one was classified
    # `step`      -- the Step that failed, when there is one
    # `workflow`  -- the Workflow the step belongs to
    def initialize(problem: nil, step: nil, workflow: nil)
      @problem = problem
      @step = step
      @workflow = workflow
    end

    def call
      step_override || template_override || work_definition_policy || problem_default
    end

    private

    attr_reader :problem, :step, :workflow

    # Tier 1. A specific step instance was told what to do -- an operator
    # decision, or a runtime patch. Nothing writes this yet.
    def step_override
      action = step&.details.to_h["remediation"]
      return nil if action.blank?

      build(action, source: :step_override)
    end

    # Tier 2. The template said what this node does on failure. The producers
    # are Workflows::Try#on_failure branches and RetryUntil's repair step;
    # both still run their own code, so this reads only what a template has
    # explicitly recorded.
    def template_override
      action = template_node_remediation
      return nil if action.blank?

      build(action, source: :template_override)
    end

    # Tier 3. The work definition's retry policy -- today's actual answer for
    # anything reached through a retry. Asking the policy rather than
    # reimplementing it is what makes this a refactor.
    def work_definition_policy
      policy = workflow&.work_definition&.retry_policy
      return nil unless policy

      if policy.respond_to?(:rebuild_unit?) && policy.rebuild_unit?(step)
        Remediation[:rebuild_unit, source: :work_definition]
      elsif policy.respond_to?(:continuation?) && policy.continuation?(step)
        Remediation[:resume_step, source: :work_definition]
      elsif policy.respond_to?(:new_attempt?) && policy.new_attempt?(step)
        Remediation[:restart_workflow, source: :work_definition]
      end
    end

    # Tier 4. The problem's own default, from Problem::Kind.
    def problem_default
      return Remediation[:fail, source: :problem_default] unless problem

      Remediation[problem.default_remediation, source: :problem_default]
    end

    def template_node_remediation
      return nil unless workflow.respond_to?(:chain_template)

      nodes = workflow.chain_template
      return nil unless nodes.is_a?(Array) && step

      node = nodes.find { |candidate| candidate.is_a?(Hash) && candidate["kind"] == step.kind }
      node && node["remediation"]
    end

    def build(action, source:)
      Remediation[action.to_sym, source: source]
    rescue ArgumentError
      # An override naming something outside the closed set is a bug in
      # whatever wrote it, not a reason to abandon the failure being handled.
      Rails.logger.warn("[Remediation] ignoring unknown #{source} action=#{action.inspect}")
      nil
    end
  end
end
