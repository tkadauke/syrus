require "rails_helper"
require Rails.root.join("db/migrate/20261025233229_add_branch_to_main_branch_health_checks")

RSpec.describe AddBranchToMainBranchHealthChecks, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:main_branch_health_checks, :branch)
    MainBranchHealth::HealthCheck.reset_column_information
  end

  it "backfills existing rows to their repository default branch" do
    migration.migrate(:down)
    MainBranchHealth::HealthCheck.reset_column_information
    repository = Factories.repository(default_branch: "develop")
    result = MainBranchHealth::HealthCheck.insert_all!([{
      repository_id: repository.id,
      sha: "abc123",
      checked_at: Time.current,
      source: "ci_poll",
      created_at: Time.current,
      updated_at: Time.current
    }])
    check_id = result.rows.first.first

    migration.migrate(:up)
    MainBranchHealth::HealthCheck.reset_column_information

    expect(MainBranchHealth::HealthCheck.find(check_id).branch).to eq("develop")
    expect(MainBranchHealth::HealthCheck.columns_hash.fetch("branch").null).to be(false)
  end
end
