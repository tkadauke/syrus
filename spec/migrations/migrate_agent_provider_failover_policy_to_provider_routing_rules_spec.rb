require "rails_helper"
require Rails.root.join("db/migrate/20260918031500_migrate_agent_provider_failover_policy_to_provider_routing_rules")

RSpec.describe MigrateAgentProviderFailoverPolicyToProviderRoutingRules, :ci_only do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
    User.reset_column_information
    ProviderRoutingRule.reset_column_information
  end

  it "backfills enabled user failover policies into default provider routing rules before dropping the column" do
    migration.down
    User.reset_column_information

    enabled_user = Factories.user
    disabled_user = Factories.user
    empty_user = Factories.user
    enabled_user.update_column(
      :agent_provider_failover_policy,
      {
        "enabled" => true,
        "providers" => %w[codex claude codex],
        "causes" => %w[usage_exhausted auth_error],
        "override_explicit_pins" => true
      }
    )
    disabled_user.update_column(
      :agent_provider_failover_policy,
      {
        "enabled" => false,
        "providers" => %w[muse codex],
        "causes" => %w[provider_transient]
      }
    )
    empty_user.update_column(
      :agent_provider_failover_policy,
      {
        "enabled" => true,
        "providers" => []
      }
    )

    migration.up
    User.reset_column_information
    ProviderRoutingRule.reset_column_information

    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(false)
    expect(ProviderRoutingRule.find_by(scope_type: "user", scope_id: enabled_user.id, task_key: "default").candidates).to eq([
      { "provider" => "claude" },
      { "provider" => "codex" }
    ])
    expect(ProviderRouting::Resolver.call(job: Factories.job(user: enabled_user, job_provider_setting: "default"), task_key: "initial").map(&:provider)).to eq(%w[
      claude
      codex
    ])
    expect(ProviderRouting::Resolver.call(job: Factories.job(user: enabled_user, job_provider_setting: "default"), task_key: "ci_failure").map(&:provider)).to eq(%w[
      claude
      codex
    ])
    expect(ProviderRoutingRule.find_by(scope_type: "user", scope_id: enabled_user.id, task_key: "default").candidates).not_to eq([
      { "provider" => "codex" },
      { "provider" => "claude" }
    ])
    expect(ProviderRoutingRule.exists?(scope_type: "user", scope_id: disabled_user.id, task_key: "default")).to be(false)
    expect(ProviderRoutingRule.exists?(scope_type: "user", scope_id: empty_user.id, task_key: "default")).to be(false)
  end
end
