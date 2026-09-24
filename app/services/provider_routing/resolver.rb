module ProviderRouting
  # Returns an ordered fallback list of provider/model/effort_level
  # candidates for a Job's task, walking specificity from the most
  # concrete override down to a hardcoded last resort. Mirrors the
  # precedence shape of Repository#effective_agent_provider and
  # Job::ProviderSetting::Default#resolve, but returns a list instead of
  # a single value so callers can fail over between candidates.
  class Resolver
    Candidate = Data.define(:provider, :model, :effort_level) do
      def to_h = super.compact
    end

    HARDCODED_FALLBACK = [ Candidate.new(provider: "claude", model: nil, effort_level: nil) ].freeze

    def self.call(job:, task_key:)
      new(job: job, task_key: task_key).call
    end

    def self.rule_configured?(job:, task_key:, include_default: true)
      new(job: job, task_key: task_key).send(:rule_configured?, include_default: include_default)
    end

    def initialize(job:, task_key:)
      @job = job
      @task_key = task_key.to_s
    end

    def call
      job_override_candidates ||
        rule_candidates(scope_type: "repository", scope_id: repository_id, task_key: task_key) ||
        rule_candidates(scope_type: "repository", scope_id: repository_id, task_key: ProviderRoutingRule::DEFAULT_TASK_KEY) ||
        repository_and_user_candidates.presence ||
        HARDCODED_FALLBACK
    end

    private

    attr_reader :job, :task_key

    def job_override_candidates
      return nil if job.job_provider_setting_default?

      # Use workflow_agent_provider so the candidate is derived from the pinned
      # job_provider_setting rather than duplicating ProviderSetting resolution
      # here. switch_job_provider_setting! keeps agent_provider in sync for
      # presentation and legacy callers, but the setting remains the source of
      # truth for explicit pins.
      [ Candidate.new(provider: job.workflow_agent_provider, model: job.model, effort_level: job.effort_level) ]
    end

    # No explicit job pin and no repository-scoped routing rule matched (a
    # repo rule -- task-specific or default-task -- is authored repo-level
    # configuration and stays authoritative on its own, handled above). From
    # here, an explicit repository/membership provider is still repo-level
    # configuration and must outrank user-scoped routing rules -- a repo
    # pinned to Muse must not be quietly routed to Claude just because the
    # user has a personal default-routing rule. But it must not foreclose
    # failover: if the repo's provider becomes unavailable, user-scoped rules
    # (and the user's own default provider) still act as the fallback chain,
    # so we concatenate rather than short-circuit. #uniq dedupes when the same
    # provider shows up in both the repo and user layers.
    def repository_and_user_candidates
      ((repository_explicit_candidates || []) + (user_scoped_candidates || [])).uniq(&:provider)
    end

    def repository_explicit_candidates
      provider = job.repository&.explicit_agent_provider(user: effective_user)
      return nil if provider.blank?

      [ Candidate.new(provider: provider, model: job.model, effort_level: job.effort_level) ]
    end

    def user_scoped_candidates
      rule_candidates(scope_type: "user", scope_id: effective_user&.id, task_key: task_key) ||
        rule_candidates(scope_type: "user", scope_id: effective_user&.id, task_key: ProviderRoutingRule::DEFAULT_TASK_KEY) ||
        default_provider_candidates
    end

    # No routing rule at any scope, and no explicit repository/membership
    # provider either. Fall back to the user's own default provider (the
    # pre-routing-rule single-value default, via User#agent_provider) before
    # the last-resort hardcoded candidate.
    def default_provider_candidates
      provider = effective_user&.agent_provider
      return nil if provider.blank?

      [ Candidate.new(provider: provider, model: job.model, effort_level: job.effort_level) ]
    end

    def rule_candidates(scope_type:, scope_id:, task_key:)
      return nil if scope_id.blank?

      rule = ProviderRoutingRule.find_by(scope_type: scope_type, scope_id: scope_id, task_key: task_key)
      return nil if rule.nil? || rule.candidates.blank?

      rule.candidates.map { |candidate| candidate_from_hash(candidate) }
    end

    def candidate_from_hash(hash)
      hash = hash.stringify_keys
      Candidate.new(provider: hash["provider"], model: hash["model"], effort_level: hash["effort_level"])
    end

    def repository_id
      job.repository_id
    end

    def effective_user
      job.owner_user || job.user
    end

    def rule_configured?(include_default:)
      keys = [ task_key ]
      keys << ProviderRoutingRule::DEFAULT_TASK_KEY if include_default
      ProviderRoutingRule.where(scope_type: "repository", scope_id: repository_id, task_key: keys).exists? ||
        ProviderRoutingRule.where(scope_type: "user", scope_id: effective_user&.id, task_key: keys).exists?
    end
  end
end
