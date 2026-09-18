class MigrateAgentProviderFailoverPolicyToProviderRoutingRules < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationProviderRoutingRule < ActiveRecord::Base
    self.table_name = "provider_routing_rules"
  end

  def up
    return unless column_exists?(:users, :agent_provider_failover_policy)
    return unless table_exists?(:provider_routing_rules)

    valid_providers = provider_keys

    MigrationUser.reset_column_information
    MigrationProviderRoutingRule.reset_column_information

    MigrationUser.where.not(agent_provider_failover_policy: nil).find_each do |user|
      policy = normalized_policy(user.agent_provider_failover_policy)
      next unless policy["enabled"]

      candidates = candidate_providers(user, policy, valid_providers).map { |provider| { "provider" => provider } }
      next if candidates.blank?

      rule = MigrationProviderRoutingRule.find_or_initialize_by(
        scope_type: "user",
        scope_id: user.id,
        task_key: "default"
      )
      rule.candidates = candidates
      rule.save!
    end

    remove_column :users, :agent_provider_failover_policy if column_exists?(:users, :agent_provider_failover_policy)
  end

  def down
    add_column :users, :agent_provider_failover_policy, :json unless column_exists?(:users, :agent_provider_failover_policy)
  end

  private

  def normalized_policy(value)
    source = value.is_a?(Hash) ? value : {}
    {
      "enabled" => ActiveModel::Type::Boolean.new.cast(source["enabled"] || source[:enabled]),
      "providers" => Array(source["providers"] || source[:providers]).map(&:to_s).reject(&:blank?).uniq
    }
  end

  def candidate_providers(user, policy, valid_providers)
    legacy_default = user.agent_provider.to_s.presence
    configured_failover_providers = policy["providers"].select do |provider|
      valid_providers.include?(provider) && provider_configured?(user, provider)
    end

    ([ legacy_default ] + configured_failover_providers).compact_blank.uniq
  end

  def provider_configured?(user, provider)
    credential_checks.fetch(provider.to_s, ->(_user) { false }).call(user)
  end

  def credential_checks
    {
      "agy" => ->(user) { user.gemini_api_key.present? },
      "claude" => ->(user) { user.claude_oauth_token.present? },
      "codex" => ->(user) { codex_configured?(user) },
      "muse" => ->(user) { user.muse_api_key.present? }
    }
  end

  def codex_configured?(user)
    if user.codex_auth_mode == "chatgpt_login"
      user.codex_auth_json.present?
    else
      user.codex_api_key.present?
    end
  end

  def provider_keys
    Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)
  rescue NameError
    %w[claude codex agy muse]
  end
end
