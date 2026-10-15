require "rails_helper"
require Rails.root.join("db/migrate/20260918031500_migrate_agent_provider_failover_policy_to_provider_routing_rules")

# The backfill half of this migration can no longer be exercised. It writes
# provider_routing_rules rows carrying only scope_type, scope_id, task_key and
# candidates, and that table has since grown user_id, position, trigger,
# conditions and action as NOT NULL columns -- so the insert raises
# NotNullViolation against today's schema no matter what data it is given.
#
# It is not reachable in production either: `up` returns early unless
# users.agent_provider_failover_policy exists, and it does not exist on any
# database that has run this migration, which is every database that also has
# today's provider_routing_rules. The pairing the old example constructed --
# the modern rules table plus the dropped users column -- is a state no
# database was ever in.
#
# Asserting it anyway is what broke the main branch for weeks. The example
# raised inside its own `after` hook, before the hook could reset the column
# cache, so the cache kept describing a column the rolled-back table no longer
# had and every later example in the serial ci_only pass that inserted a user
# died. What stays worth asserting is the guards, because the guards are what
# actually run.
RSpec.describe MigrateAgentProviderFailoverPolicyToProviderRoutingRules, :ci_only do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    connection.remove_column(:users, :agent_provider_failover_policy) if connection.column_exists?(:users, :agent_provider_failover_policy)
  ensure
    User.reset_column_information
    ProviderRoutingRule.reset_column_information
  end

  it "is a no-op on a database that has already dropped the column" do
    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(false)

    expect { migration.up }.not_to raise_error

    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(false)
  end

  it "drops the column again when a down migration has restored it" do
    migration.down
    User.reset_column_information
    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(true)

    migration.up
    User.reset_column_information

    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(false)
  end

  it "leaves the down migration idempotent" do
    migration.down
    User.reset_column_information

    expect { migration.down }.not_to raise_error
    expect(connection.column_exists?(:users, :agent_provider_failover_policy)).to be(true)
  end
end
