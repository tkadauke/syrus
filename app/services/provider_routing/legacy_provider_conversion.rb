module ProviderRouting
  # One-shot conversion of the retired single-value `repositories.agent_provider`
  # and `repository_memberships.agent_provider` columns into equivalent
  # ProviderRoutingRules, so dropping the columns does not change which
  # provider any repository uses.
  #
  # Input is plain row hashes (read with raw SQL by the migration) so this keeps
  # working after the columns are gone from the schema:
  #   repository_rows: [{ id:, owner:, name:, user_id:, agent_provider: }]
  #   membership_rows: [{ repository_id:, user_id:, role:, agent_provider: }]
  #
  # - Repository pin  -> repository-scoped default rule (fallback_order, one
  #   candidate), appended after any existing repository rules. Skipped when the
  #   repository already has its own default rule.
  # - Membership pin  -> the user's own default rule limited to that repository
  #   (conditions.repository.ids), placed first among the user's rules. Repository
  #   rules are owner-scoped, so a per-member rule has to live at user scope.
  #   Only write-tier-or-better memberships ever counted.
  # - Idempotent: a re-run finds the rules it created and skips them.
  # - SKIPPED_PINS lists pins that must not be turned into a rule because the
  #   rule would just recreate the problem this change fixes (a codex pin that
  #   outranked the owner's Claude-then-Codex routing). They are logged.
  class LegacyProviderConversion
    SKIPPED_PINS = { "tkadauke/syrus" => %w[ codex ] }.freeze

    Result = Struct.new(:converted, :skipped, :warnings, keyword_init: true)

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(repository_rows:, membership_rows:, skipped_pins: SKIPPED_PINS, logger: nil)
      @repository_rows = repository_rows
      @membership_rows = membership_rows
      @skipped_pins = skipped_pins
      @logger = logger
      @result = Result.new(converted: [], skipped: [], warnings: [])
    end

    def call
      repositories = @repository_rows.index_by { |row| row.fetch(:id) }
      repositories.each_value { |row| convert_repository(row) }
      @membership_rows.each { |row| convert_membership(row, repositories[row.fetch(:repository_id)]) }
      @result
    end

    private

    def convert_repository(row)
      provider = row[:agent_provider].to_s.strip
      return if provider.blank?

      slug = "#{row[:owner]}/#{row[:name]}"
      if Array(@skipped_pins[slug]).include?(provider)
        return skip("repository #{slug}: legacy pin #{provider} not converted (deliberately skipped; routing rules decide)")
      end
      return skip("repository #{slug}: no owner user, cannot create a rule") if row[:user_id].blank?
      if ProviderRoutingRule.where(scope_type: "repository", scope_id: row.fetch(:id)).any? { |rule| default_trigger?(rule) }
        return skip("repository #{slug}: already has a default routing rule, pin #{provider} dropped")
      end

      save_rule("repository #{slug}: pin #{provider} -> repository default rule",
        ProviderRoutingRule.new(scope_type: "repository", scope_id: row.fetch(:id), repository_id: row.fetch(:id),
          user_id: row.fetch(:user_id), task_key: ProviderRoutingRule::DEFAULT_TASK_KEY,
          trigger: { "type" => "default" }, conditions: {}, action: action_for(provider), candidates: [ candidate_for(provider) ]))
    end

    def convert_membership(row, repository_row)
      provider = row[:agent_provider].to_s.strip
      return if provider.blank?
      return unless RepositoryMembership::ROLE_RANK.fetch(row[:role].to_s, -1) >= RepositoryMembership::ROLE_RANK.fetch("write")

      repository_id = row.fetch(:repository_id)
      user_id = row.fetch(:user_id)
      slug = repository_row ? "#{repository_row[:owner]}/#{repository_row[:name]}" : "repository #{repository_id}"
      label = "membership user=#{user_id} on #{slug}"
      if ProviderRoutingRule.where(scope_type: "user", scope_id: user_id).any? { |rule| default_trigger?(rule) && repository_ids(rule) == [ repository_id ] }
        return skip("#{label}: already has a repository-limited default rule, pin #{provider} dropped")
      end
      if ProviderRoutingRule.where(scope_type: "repository", scope_id: repository_id).exists?
        @result.warnings << "#{label}: repository routing rules outrank user rules, so this member override of #{provider} may be shadowed"
        log(@result.warnings.last)
      end

      rule = ProviderRoutingRule.new(scope_type: "user", scope_id: user_id, user_id: user_id, task_key: ProviderRoutingRule::DEFAULT_TASK_KEY,
        trigger: { "type" => "default" }, conditions: { "repository" => { "ids" => [ repository_id ] } },
        action: action_for(provider), candidates: [ candidate_for(provider) ])
      ProviderRoutingRule.transaction do
        shift_user_rules(user_id)
        rule.position = 1
        save_rule("#{label}: pin #{provider} -> user default rule limited to the repository", rule)
        raise ActiveRecord::Rollback unless rule.persisted?
      end
    end

    # Make room at position 1 (unique per scope), highest position first.
    def shift_user_rules(user_id)
      ProviderRoutingRule.where(scope_type: "user", scope_id: user_id).order(position: :desc).each do |existing|
        existing.update_column(:position, existing.position + 1)
      end
    end

    def save_rule(description, rule)
      if rule.save
        @result.converted << description
        log("converted #{description}")
      else
        skip("#{description} FAILED: #{rule.errors.full_messages.to_sentence}")
      end
    end

    def skip(message)
      @result.skipped << message
      log("skipped #{message}")
    end

    def log(message)
      @logger&.call("[legacy-provider-conversion] #{message}")
    end

    def default_trigger?(rule) = rule.trigger.to_h["type"] == "default"
    def repository_ids(rule) = Array(rule.conditions.to_h.dig("repository", "ids")).map(&:to_i)
    def candidate_for(provider) = { "provider" => provider }
    def action_for(provider) = { "strategy" => "fallback_order", "candidates" => [ candidate_for(provider) ] }
  end
end
