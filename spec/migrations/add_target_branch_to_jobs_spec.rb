require "rails_helper"
require Rails.root.join("db/migrate/20260816033342_add_target_branch_to_jobs")

RSpec.describe AddTargetBranchToJobs, :ci_only do
  it "is idempotent when run more than once" do
    migration = described_class.new

    expect {
      migration.change
      migration.change
    }.not_to raise_error

    expect(ActiveRecord::Base.connection.column_exists?(:jobs, :target_branch)).to eq(true)
  end
end
