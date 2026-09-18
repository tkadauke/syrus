require "rails_helper"
require Rails.root.join("db/migrate/20260918120000_migrate_agent_provider_failover_policy_to_provider_routing_rules")

RSpec.describe MigrateAgentProviderFailoverPolicyToProviderRoutingRules, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    add_legacy_column
    example.run
  ensure
    ProviderRoutingRule.delete_all if connection.table_exists?(:provider_routing_rules)
    remove_legacy_column
  end

  it "creates user default routing rules from enabled legacy policies and removes the old column" do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
    enabled_user = Factories.user(
      agent_provider: "claude",
      codex_auth_mode: "api_key",
      codex_api_key: "sk-codex",
      muse_api_key: "muse-secret"
    )
    unconfigured_user = Factories.user(agent_provider: "claude")
    disabled_user = Factories.user(agent_provider: "codex")
    described_class::MigrationUser.reset_column_information
    described_class::MigrationUser.where(id: enabled_user.id).update_all(
      agent_provider_failover_policy: {
        "enabled" => true,
        "providers" => %w[codex claude muse],
        "causes" => %w[usage_low rate_limited],
        "override_explicit_pins" => true
      }
    )
    described_class::MigrationUser.where(id: disabled_user.id).update_all(
      agent_provider_failover_policy: {
        "enabled" => false,
        "providers" => %w[claude]
      }
    )
    described_class::MigrationUser.where(id: unconfigured_user.id).update_all(
      agent_provider_failover_policy: {
        "enabled" => true,
        "providers" => %w[codex]
      }
    )

    migration.up
    connection.schema_cache.clear!

    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be false
    expect(ProviderRoutingRule.find_by(scope_type: "user", scope_id: disabled_user.id, task_key: "default")).to be_nil
    expect(ProviderRoutingRule.find_by!(scope_type: "user", scope_id: unconfigured_user.id, task_key: "default").candidates).to eq([
      { "provider" => "claude" }
    ])
    expect(ProviderRoutingRule.find_by!(scope_type: "user", scope_id: enabled_user.id, task_key: "default").candidates).to eq([
      { "provider" => "claude" },
      { "provider" => "codex" },
      { "provider" => "muse" }
    ])
  end

  private

  def add_legacy_column
    return if connection.column_exists?(:users, :agent_provider_failover_policy)

    connection.add_column(:users, :agent_provider_failover_policy, :json)
    connection.schema_cache.clear!
    User.reset_column_information
  end

  def remove_legacy_column
    return unless connection.column_exists?(:users, :agent_provider_failover_policy)

    connection.remove_column(:users, :agent_provider_failover_policy)
    connection.schema_cache.clear!
    User.reset_column_information
  end
end
