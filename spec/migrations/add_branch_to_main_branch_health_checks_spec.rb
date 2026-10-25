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
    check = MainBranchHealthCheck.create!(repository: repository, sha: "abc123", checked_at: Time.current, source: "ci_poll")

    migration.migrate(:up)
    MainBranchHealthCheck.reset_column_information

    expect(check.reload.branch).to eq("develop")
    expect(MainBranchHealthCheck.columns_hash.fetch("branch").null).to be(false)
  end
end
