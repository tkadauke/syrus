require "rails_helper"
require Rails.root.join("db/migrate/20261019142911_add_enabled_to_provider_routing_rules")

RSpec.describe AddEnabledToProviderRoutingRules, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:provider_routing_rules, :enabled)
    ProviderRoutingRule.reset_column_information
  end

  it "defaults existing and new rules to enabled" do
    migration.migrate(:down)
    ProviderRoutingRule.reset_column_information
    user = Factories.user
    rule = ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, user_id: user.id, task_key: "default", candidates: [])

    migration.migrate(:up)
    ProviderRoutingRule.reset_column_information

    expect(rule.reload).to be_enabled
    column = ProviderRoutingRule.columns_hash.fetch("enabled")
    expect(column.null).to be(false)
    expect(ActiveModel::Type::Boolean.new.cast(column.default)).to be(true)
  end
end
