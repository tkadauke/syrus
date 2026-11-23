require "rails_helper"
require Rails.root.join("plugins/main_branch_health/db/migrate/20261123013516_move_main_branch_health_storage_to_plugin")

RSpec.describe MoveMainBranchHealthStorageToPlugin, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  it "round-trips populated storage and can rerun the up migration" do
    repository = Factories.repository(
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      main_branch_repair_blocks_work: true,
      ci_health: "broken",
      grader_health: "healthy",
      last_health_checked_sha: "health123"
    )
    AppSetting.current.update!(main_concern_report_threshold: 5)

    migration.migrate(:down)
    reset_columns
    row = connection.select_one("SELECT * FROM repositories WHERE id = #{connection.quote(repository.id)}")
    expect(row).to include(
      "main_branch_health_enabled" => a_truthy_value,
      "main_branch_repair_enabled" => a_truthy_value,
      "main_branch_repair_blocks_work" => a_truthy_value,
      "ci_health" => "broken",
      "grader_health" => "healthy",
      "last_health_checked_sha" => "health123"
    )
    expect(connection.select_value("SELECT main_concern_report_threshold FROM app_settings").to_i).to eq(5)

    migration.migrate(:up)
    migration.migrate(:up)
    reset_columns
    expect(MainBranchHealth::RepositoryState.find_by!(repository_id: repository.id)).to have_attributes(
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      main_branch_repair_blocks_work: true,
      ci_health: "broken",
      grader_health: "healthy",
      last_health_checked_sha: "health123"
    )
    expect(MainBranchHealth::Setting.current.main_concern_report_threshold).to eq(5)
  ensure
    migration.migrate(:up) if connection.column_exists?(:repositories, :main_branch_health_enabled)
    reset_columns
  end

  it "refuses to drop the core setting when its value was not copied" do
    AppSetting.current.update!(main_concern_report_threshold: 7)
    migration.migrate(:down)
    reset_columns
    allow(migration).to receive(:copy_instance_data)

    expect { migration.migrate(:up) }
      .to raise_error(ActiveRecord::MigrationError, /instance setting copy did not verify/)
    expect(connection.column_exists?(:app_settings, :main_concern_report_threshold)).to be(true)
  ensure
    described_class.new.migrate(:up) if connection.column_exists?(:app_settings, :main_concern_report_threshold)
    reset_columns
  end

  def reset_columns
    connection.schema_cache.clear!
    Repository.reset_column_information
    AppSetting.reset_column_information
    MainBranchHealth::RepositoryState.reset_column_information if connection.table_exists?(:main_branch_health_repository_states)
  end
end
