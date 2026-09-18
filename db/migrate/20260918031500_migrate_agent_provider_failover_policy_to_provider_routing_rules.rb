class MigrateAgentProviderFailoverPolicyToProviderRoutingRules < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationProviderRoutingRule < ActiveRecord::Base
    self.table_name = "provider_routing_rules"
  end

  DEFAULT_TASK_KEY = "default".freeze

  def up
    return unless column_exists?(:users, :agent_provider_failover_policy)
    return unless table_exists?(:provider_routing_rules)

    migrate_enabled_policies
    remove_column :users, :agent_provider_failover_policy if column_exists?(:users, :agent_provider_failover_policy)
  end

  def down
    add_column :users, :agent_provider_failover_policy, :json unless column_exists?(:users, :agent_provider_failover_policy)
  end

  private

  def migrate_enabled_policies
    MigrationUser.reset_column_information
    MigrationProviderRoutingRule.reset_column_information

    now = Time.current
    MigrationUser.where.not(agent_provider_failover_policy: nil).find_each do |user|
      candidates = candidates_for(user)
      next if candidates.empty?

      rule = MigrationProviderRoutingRule.find_or_initialize_by(
        scope_type: "user",
        scope_id: user.id,
        task_key: DEFAULT_TASK_KEY
      )
      rule.created_at ||= now
      rule.update!(candidates: candidates, updated_at: now)
    end
  end

  def candidates_for(user)
    policy = user.agent_provider_failover_policy
    return [] unless policy.is_a?(Hash)
    return [] unless ActiveModel::Type::Boolean.new.cast(policy["enabled"] || policy[:enabled])

    providers = [ user.agent_provider, *Array(policy["providers"] || policy[:providers]) ].map(&:to_s).reject(&:blank?).uniq
    return [] if providers.one?

    providers.map { |provider| { "provider" => provider } }
  end
end
