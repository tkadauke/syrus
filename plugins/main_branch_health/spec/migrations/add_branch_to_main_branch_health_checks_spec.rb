require "rails_helper"
require Rails.root.join("db/migrate/20261025233229_add_branch_to_main_branch_health_checks")

# The table this historical migration targets was later renamed into the
# plugin's namespace. The spec runs the migration against the table under its
# old name so the default-branch backfill stays covered, then restores it.
RSpec.describe AddBranchToMainBranchHealthChecks, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:legacy_table) { :main_branch_health_checks }
  let(:current_table) { :main_branch_health_health_checks }

  before { connection.rename_table(current_table, legacy_table) }

  after do
    migration.migrate(:up) unless connection.column_exists?(legacy_table, :branch)
    connection.rename_table(legacy_table, current_table)
    MainBranchHealth::HealthCheck.reset_column_information
  end

  it "backfills existing rows to their repository default branch" do
    migration.migrate(:down)
    repository = Factories.repository(default_branch: "develop")
    now = connection.quote(Time.current.utc.to_fs(:db))
    connection.execute(<<~SQL.squish)
      INSERT INTO #{legacy_table} (repository_id, sha, checked_at, source, created_at, updated_at)
      VALUES (#{repository.id}, 'abc123', #{now}, 'ci_poll', #{now}, #{now})
    SQL
    check_id = connection.select_value("SELECT id FROM #{legacy_table} WHERE repository_id = #{repository.id}")

    migration.migrate(:up)

    expect(connection.select_value("SELECT branch FROM #{legacy_table} WHERE id = #{check_id}")).to eq("develop")
    expect(connection.columns(legacy_table).find { |column| column.name == "branch" }.null).to be(false)
  end
end
