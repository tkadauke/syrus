module ProviderRouting
  # A handful of step kinds can carry their own routing-rule task_key,
  # distinct from the workflow-kind default that drives the rest of the
  # workflow's Runs -- e.g. always route `adversarial_review` through a
  # stronger/cheaper model than `implement` regardless of the workflow's
  # own provider. Resolution only kicks in when a ProviderRoutingRule
  # actually exists for that step's task_key; otherwise the caller should
  # fall back to the workflow-kind-level resolution as usual.
  module StepTaskKey
    STEP_KINDS = %w[ adversarial_review ].freeze

    def self.for(step, job)
      return nil unless STEP_KINDS.include?(step.kind)
      return nil unless rule_exists?(step.kind, job)

      step.kind
    end

    def self.rule_exists?(task_key, job)
      scopes(job).any? do |scope_type, scope_id|
        scope_id.present? && ProviderRoutingRule.exists?(scope_type: scope_type, scope_id: scope_id, task_key: task_key)
      end
    end

    def self.scopes(job)
      effective_user = job.owner_user || job.user
      [ [ "repository", job.repository_id ], [ "user", effective_user&.id ] ]
    end
  end
end
