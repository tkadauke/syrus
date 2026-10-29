require "rails_helper"
require Rails.root.join("db/migrate/20261025233229_add_branch_to_main_branch_health_checks")

RSpec.describe AddBranchToMainBranchHealthChecks, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:main_branch_health_checks, :branch)
    MainBranchHealthCheck.reset_column_information
  end

  it "backfills existing rows to their repository default branch" do
    migration.migrate(:down)
    MainBranchHealthCheck.reset_column_information
    repository = Factories.repository(default_branch: "develop")
    legacy_health_check = Class.new(ApplicationRecord) do
      self.table_name = "main_branch_health_checks"
    end
    check_id = legacy_health_check.create!(repository_id: repository.id, sha: "abc123", checked_at: Time.current, source: "ci_poll").id

    migration.migrate(:up)
    MainBranchHealthCheck.reset_column_information

    expect(MainBranchHealthCheck.find(check_id).branch).to eq("develop")
    expect(MainBranchHealthCheck.columns_hash.fetch("branch").null).to be(false)
  end
end
