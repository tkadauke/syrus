class MoveMainBranchHealthStorageToPlugin < ActiveRecord::Migration[8.1]
  REPOSITORY_COLUMNS = {
    ci_health: [ :string, { default: "unknown", null: false } ],
    grader_health: [ :string, { default: "unknown", null: false } ],
    last_health_checked_sha: [ :string, {} ],
    landing_paused: [ :boolean, { default: false, null: false } ],
    main_branch_health_enabled: [ :boolean, { default: false, null: false } ],
    main_branch_repair_enabled: [ :boolean, { default: false, null: false } ],
    last_graded_sha: [ :string, {} ],
    last_ci_evaluated_sha: [ :string, {} ],
    main_branch_repair_auto_approve: [ :boolean, { default: false, null: false } ],
    main_health_poll_error_streak: [ :integer, { default: 0, null: false } ],
    last_main_health_poll_error_at: [ :datetime, {} ],
    main_branch_repair_blocks_work: [ :boolean, { default: false, null: false } ]
  }.freeze

  def up
    create_repository_states
    create_settings
    copy_repository_data
    copy_instance_data
    verify_copy!
    rename_plugin_tables
    REPOSITORY_COLUMNS.each_key do |column|
      remove_column :repositories, column if column_exists?(:repositories, column)
    end
    remove_column :app_settings, :main_concern_report_threshold if column_exists?(:app_settings, :main_concern_report_threshold)
  end

  def down
    REPOSITORY_COLUMNS.each do |column, (type, options)|
      add_column :repositories, column, type, **options unless column_exists?(:repositories, column)
    end
    add_column :app_settings, :main_concern_report_threshold, :integer, default: 2, null: false unless column_exists?(:app_settings, :main_concern_report_threshold)

    if table_exists?(:main_branch_health_repository_states)
      assignments = REPOSITORY_COLUMNS.keys.map do |column|
        "#{column} = (SELECT #{column} FROM main_branch_health_repository_states " \
          "WHERE main_branch_health_repository_states.repository_id = repositories.id)"
      end.join(", ")
      execute <<~SQL.squish
        UPDATE repositories SET #{assignments} WHERE EXISTS (
          SELECT 1 FROM main_branch_health_repository_states
          WHERE main_branch_health_repository_states.repository_id = repositories.id
        )
      SQL
    end
    if table_exists?(:main_branch_health_settings)
      execute <<~SQL.squish
        UPDATE app_settings SET main_concern_report_threshold = (
          SELECT main_concern_report_threshold FROM main_branch_health_settings ORDER BY id LIMIT 1
        ) WHERE EXISTS (SELECT 1 FROM main_branch_health_settings)
      SQL
    end

    rename_table :main_branch_health_health_checks, :main_branch_health_checks if table_exists?(:main_branch_health_health_checks) && !table_exists?(:main_branch_health_checks)
    rename_table :main_branch_health_concern_reports, :main_concern_reports if table_exists?(:main_branch_health_concern_reports) && !table_exists?(:main_concern_reports)
    drop_table :main_branch_health_repository_states, if_exists: true
    drop_table :main_branch_health_settings, if_exists: true
  end

  private

  def create_repository_states
    create_table :main_branch_health_repository_states, if_not_exists: true do |t|
      t.bigint :repository_id, null: false
      t.string :ci_health, default: "unknown", null: false
      t.string :grader_health, default: "unknown", null: false
      t.string :last_health_checked_sha
      t.boolean :landing_paused, default: false, null: false
      t.boolean :main_branch_health_enabled, default: false, null: false
      t.boolean :main_branch_repair_enabled, default: false, null: false
      t.string :last_graded_sha
      t.string :last_ci_evaluated_sha
      t.boolean :main_branch_repair_auto_approve, default: false, null: false
      t.integer :main_health_poll_error_streak, default: 0, null: false
      t.datetime :last_main_health_poll_error_at
      t.boolean :main_branch_repair_blocks_work, default: false, null: false
      t.timestamps
    end
    add_index :main_branch_health_repository_states, :repository_id, unique: true unless index_exists?(:main_branch_health_repository_states, :repository_id, unique: true)
  end

  def create_settings
    create_table :main_branch_health_settings, if_not_exists: true do |t|
      t.integer :main_concern_report_threshold, default: 2, null: false
      t.timestamps
    end
  end

  def copy_repository_data
    return unless REPOSITORY_COLUMNS.keys.all? { |column| column_exists?(:repositories, column) }

    columns = REPOSITORY_COLUMNS.keys.join(", ")
    execute <<~SQL.squish
      INSERT INTO main_branch_health_repository_states
        (repository_id, #{columns}, created_at, updated_at)
      SELECT repositories.id, #{columns}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM repositories
      WHERE NOT EXISTS (
        SELECT 1 FROM main_branch_health_repository_states
        WHERE main_branch_health_repository_states.repository_id = repositories.id
      )
    SQL
  end

  def copy_instance_data
    return unless column_exists?(:app_settings, :main_concern_report_threshold)
    return if select_value("SELECT COUNT(*) FROM main_branch_health_settings").to_i.positive?

    execute <<~SQL.squish
      INSERT INTO main_branch_health_settings (main_concern_report_threshold, created_at, updated_at)
      SELECT main_concern_report_threshold, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM app_settings ORDER BY id LIMIT 1
    SQL
  end

  def verify_copy!
    verify_repository_copy! if REPOSITORY_COLUMNS.keys.all? { |column| column_exists?(:repositories, column) }
    verify_instance_copy! if column_exists?(:app_settings, :main_concern_report_threshold)
  end

  def verify_repository_copy!

    source_count = select_value("SELECT COUNT(*) FROM repositories").to_i
    copied_count = select_value("SELECT COUNT(*) FROM main_branch_health_repository_states").to_i
    raise ActiveRecord::MigrationError, "main-branch health repository copy was incomplete" unless source_count == copied_count

    REPOSITORY_COLUMNS.each_key do |column|
      mismatch = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*) FROM repositories r
        JOIN main_branch_health_repository_states s ON s.repository_id = r.id
        WHERE NOT (r.#{column} = s.#{column} OR (r.#{column} IS NULL AND s.#{column} IS NULL))
      SQL
      raise ActiveRecord::MigrationError, "main-branch health #{column} copy did not verify" if mismatch.positive?
    end
  end

  def verify_instance_copy!
    source_count = select_value("SELECT COUNT(*) FROM app_settings").to_i
    return if source_count.zero?

    source = select_value("SELECT main_concern_report_threshold FROM app_settings ORDER BY id LIMIT 1")
    copied = select_value("SELECT main_concern_report_threshold FROM main_branch_health_settings ORDER BY id LIMIT 1")
    raise ActiveRecord::MigrationError, "main-branch health instance setting copy did not verify" unless copied.to_s == source.to_s
  end

  def rename_plugin_tables
    rename_table :main_branch_health_checks, :main_branch_health_health_checks if table_exists?(:main_branch_health_checks) && !table_exists?(:main_branch_health_health_checks)
    rename_table :main_concern_reports, :main_branch_health_concern_reports if table_exists?(:main_concern_reports) && !table_exists?(:main_branch_health_concern_reports)
  end
end
