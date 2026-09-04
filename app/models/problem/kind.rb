class Problem
  # The shared failure vocabulary (workflow-engine-v3 primitive A).
  #
  # One event used to be renamed on every hop between control planes. A push
  # rejected because the remote branch moved was `branch_diverged` to
  # RunFailureClassifier, `remote_branch_advanced_rebase_conflict` to the Step
  # detail a Workflows::Try branch matches on, and `branch_diverged_pr_open` to
  # WorkEngine::Reconciler -- four names, one event, and nothing checking the
  # translations.
  #
  # This registry is the single set of codes. Every plane keeps the name it
  # already writes, but each of those names is declared here as an alias of one
  # canonical code, so the relationship is data instead of convention.
  #
  # `scope` says what the problem is about, which is what decides who can act
  # on it:
  #   :run       -- this attempt failed; a retry is meaningful
  #   :step      -- this step failed in a way a sibling branch can handle
  #   :workflow  -- the whole attempt is invalid; restarting is the unit
  #   :unit      -- a multi-member WorkUnit is wrong; rebuilding is the unit
  #   :external  -- the world outside Syrus moved; nothing local to retry
  #
  # `default_remediation` is the action taken when no more specific override
  # applies. It names an action from the closed set primitive B introduces; A1
  # only records it, so nothing reads it yet -- the current remediation paths
  # are untouched. Seeding it now is what makes B a table lookup rather than a
  # second inventory.
  module Kind
    SCOPES = %i[run step workflow unit external].freeze

    # The closed action set from primitive B. Recorded, not yet dispatched on.
    REMEDIATIONS = %i[
      retry_step resume_step repair_with insert branch skip advance
      restart_workflow rebuild_unit defer preempt escalate fail
    ].freeze

    Entry = Data.define(:code, :scope, :retryable, :default_remediation,
                        :failure_codes, :issue_kinds, :label) do
      def initialize(code:, scope:, retryable:, default_remediation:,
                     failure_codes: [], issue_kinds: [], label: nil)
        raise ArgumentError, "unknown problem scope=#{scope.inspect}" unless SCOPES.include?(scope)
        raise ArgumentError, "unknown remediation=#{default_remediation.inspect}" unless REMEDIATIONS.include?(default_remediation)

        super(
          code: code.to_s,
          scope: scope,
          retryable: !!retryable,
          default_remediation: default_remediation,
          # Names other planes already write for this same problem.
          failure_codes: Array(failure_codes).map(&:to_s).freeze,
          issue_kinds: Array(issue_kinds).map(&:to_s).freeze,
          label: label || code.to_s.humanize
        )
      end

      # Every string that resolves to this problem, canonical code included.
      def aliases = ([ code ] + failure_codes + issue_kinds).freeze
    end

    BUILT_IN_ENTRIES = [
      # -- Infrastructure the run happened to land on -------------------------
      Entry.new(code: "worker_died", scope: :run, retryable: true,
                default_remediation: :retry_step,
                issue_kinds: %w[stale_running_run missed_worker_death_auto_retry]),
      Entry.new(code: "worker_died_under_resource_pressure", scope: :run, retryable: false,
                default_remediation: :escalate,
                label: "Worker died under resource pressure"),
      Entry.new(code: "timeout", scope: :run, retryable: true, default_remediation: :retry_step),
      Entry.new(code: "database_lock", scope: :run, retryable: true, default_remediation: :retry_step),
      Entry.new(code: "database_capacity", scope: :run, retryable: true, default_remediation: :retry_step),

      # -- The workspace ------------------------------------------------------
      Entry.new(code: "workspace_checkout_invalid", scope: :run, retryable: true,
                default_remediation: :retry_step),
      Entry.new(code: "workspace_clone_timeout", scope: :run, retryable: true,
                default_remediation: :retry_step),
      Entry.new(code: "git_state_corrupt", scope: :workflow, retryable: false,
                default_remediation: :restart_workflow),
      Entry.new(code: "git_failure", scope: :run, retryable: false, default_remediation: :escalate),
      Entry.new(code: "empty_commit", scope: :step, retryable: false, default_remediation: :advance),

      # -- The agent and its provider ----------------------------------------
      Entry.new(code: "agent_gave_up_waiting", scope: :run, retryable: true,
                default_remediation: :resume_step),
      Entry.new(code: "agent_resume_unavailable", scope: :run, retryable: true,
                default_remediation: :retry_step),
      Entry.new(code: "agent_max_turns", scope: :run, retryable: false, default_remediation: :escalate),
      Entry.new(code: "agent_invocation_too_large", scope: :run, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "missing_required_tool_call", scope: :run, retryable: true,
                default_remediation: :retry_step),
      Entry.new(code: "stdin_race_failed", scope: :run, retryable: true, default_remediation: :retry_step),
      Entry.new(code: "mcp_sidecar_failure", scope: :run, retryable: true, default_remediation: :retry_step),
      Entry.new(code: "provider_transient", scope: :run, retryable: true, default_remediation: :retry_step),
      Entry.new(code: "provider_auth_expired", scope: :external, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "provider_auth_or_config", scope: :external, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "provider_prompt_too_long", scope: :run, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "provider_usage_limit", scope: :external, retryable: true,
                default_remediation: :defer),
      Entry.new(code: "rate_limited", scope: :external, retryable: true, default_remediation: :defer),

      # -- The work itself ----------------------------------------------------
      Entry.new(code: "grader_failure", scope: :step, retryable: false,
                default_remediation: :repair_with),
      Entry.new(code: "validation_or_user_error", scope: :run, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "application_error", scope: :run, retryable: false,
                default_remediation: :escalate),

      # -- The world moved underneath us -------------------------------------
      #
      # The plan's worked example: three planes, three names, one event.
      Entry.new(code: "branch_diverged", scope: :external, retryable: false,
                default_remediation: :branch,
                failure_codes: %w[remote_branch_advanced_rebase_conflict],
                issue_kinds: %w[branch_diverged_pr_open stale_branch_diverged_workflow]),
      Entry.new(code: "pr_open_no_commits_between", scope: :external, retryable: false,
                default_remediation: :advance),
      Entry.new(code: "merge_train_rebase_conflict", scope: :unit, retryable: false,
                default_remediation: :escalate),
      Entry.new(code: "merge_train_rebuild_required", scope: :unit, retryable: false,
                default_remediation: :rebuild_unit,
                failure_codes: %w[merge_train_base_moved])
    ].freeze

    REGISTRY = Syrus::KindRegistry.new(
      built_in: BUILT_IN_ENTRIES, entry_class: Entry, provider_method: :problem_kinds, key: :code
    )

    def self.entries = REGISTRY.entries
    def self.by_code = REGISTRY.by_key

    module_function

    def values = by_code.keys.freeze

    def fetch(code)
      by_code.fetch(code.to_s) do
        raise ArgumentError, "unknown problem code=#{code.inspect}"
      end
    end

    def exists?(code) = by_code.key?(code.to_s)

    # Resolves any plane's name for a problem -- canonical code, the
    # `failure_code` a Step stamps for a Try branch, or a reconciler issue
    # kind -- to the one entry. Returns nil for a name no plane has declared,
    # so callers can fall back rather than raise on an unmapped string.
    def resolve(name)
      alias_index[name.to_s]
    end

    def alias_index
      entries.each_with_object({}) do |entry, index|
        entry.aliases.each { |name| index[name] = entry }
      end.freeze
    end

    def scope_for(code) = fetch(code).scope
    def retryable?(code) = fetch(code).retryable
    def default_remediation_for(code) = fetch(code).default_remediation
  end
end
