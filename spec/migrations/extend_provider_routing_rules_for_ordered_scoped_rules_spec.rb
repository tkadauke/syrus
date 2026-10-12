require "rails_helper"
require Rails.root.join("db/migrate/20261011235013_extend_provider_routing_rules_for_ordered_scoped_rules")

RSpec.describe ExtendProviderRoutingRulesForOrderedScopedRules, :ci_only do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
    ProviderRoutingRule.reset_column_information
  end

  it "backfills repository-scoped rules for repositories without a direct owner" do
    migration.down
    ProviderRoutingRule.reset_column_information

    repository_owner = Factories.user
    admin_member = Factories.user
    repository = Factories.repository(user: repository_owner)
    repository.update_column(:user_id, nil)
    repository.repository_memberships.delete_all
    repository.repository_memberships.create!(user: admin_member, role: "admin")

    timestamp = connection.quote(Time.current)
    candidates = connection.quote([{ provider: "claude" }].to_json)
    connection.execute(<<~SQL.squish)
      INSERT INTO provider_routing_rules (scope_type, scope_id, task_key, candidates, created_at, updated_at)
      VALUES ('repository', #{repository.id}, 'default', #{candidates}, #{timestamp}, #{timestamp})
    SQL

    migration.up
    ProviderRoutingRule.reset_column_information

    rule = ProviderRoutingRule.find_by!(scope_type: "repository", scope_id: repository.id)
    expect(rule.user_id).to eq(admin_member.id)
    expect(rule.trigger).to eq("type" => "default")
  end
end
