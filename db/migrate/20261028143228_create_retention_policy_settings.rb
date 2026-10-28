class CreateRetentionPolicySettings < ActiveRecord::Migration[8.1]
  POLICIES = {
    job_log: [ :job_log_retention_days, :days, :job_log_archive_before_delete ],
    performance_log_event: [ :performance_log_event_retention_hours, :hours, nil ],
    run_diagnostic: [ :run_diagnostic_retention_days, :days, :run_diagnostic_archive_before_delete ],
    run_resource_summary: [ :run_resource_summary_retention_days, :days, nil ],
    worker_host_health_sample: [ :worker_host_health_sample_retention_days, :days, nil ],
    work_engine_reconciler_activity: [ :work_engine_reconciler_activity_retention_days, :days, :work_engine_reconciler_activity_archive_before_delete ],
    provider_session: [ :provider_session_retention_days, :days, :provider_session_archive_before_delete ],
    spawned_process: [ :spawned_process_retention_days, :days, nil ],
    notification: [ :notification_retention_days, :days, nil ],
    operational_log_event: [ :operational_log_event_retention_hours, :hours, nil ],
    metrics_dashboard_sample: [ :metrics_dashboard_sample_retention_days, :days, nil ],
    run_health_snapshot: [ :run_health_snapshot_retention_days, :days, :run_health_snapshot_archive_before_delete ],
    main_branch_health_check: [ :main_branch_health_check_retention_days, :days, :main_branch_health_check_archive_before_delete ],
    workflow_step_resource_profile: [ :workflow_step_resource_profile_retention_days, :days, nil ],
    test_insight_case: [ :test_insight_case_retention_days, :days, nil ]
  }.freeze

  def change
    create_table :retention_policy_settings do |t|
      t.string :retention_key, null: false
      t.bigint :retention_seconds
      t.boolean :archive_before_delete
      t.timestamps
    end
    add_index :retention_policy_settings, :retention_key, unique: true unless index_exists?(:retention_policy_settings, :retention_key)

    reversible do |direction|
      direction.up { migrate_from_app_settings }
      direction.down { restore_to_app_settings }
    end
  end

  private

  def migrate_from_app_settings
    setting = select_one("SELECT * FROM app_settings ORDER BY id LIMIT 1")
    POLICIES.each do |key, (column, unit, archive_column)|
      next unless column_exists?(:app_settings, column)

      value = setting ? setting[column.to_s].to_i : column_default(column).to_i
      seconds = value.zero? ? nil : value * unit_seconds(unit)
      archive = archive_column && column_exists?(:app_settings, archive_column) ? truthy?(setting&.fetch(archive_column.to_s, false)) : nil
      quoted_archive = archive.nil? ? "NULL" : (archive ? "1" : "0")
      execute <<~SQL.squish
        INSERT INTO retention_policy_settings
          (retention_key, retention_seconds, archive_before_delete, created_at, updated_at)
        VALUES
          (#{connection.quote(key.to_s)}, #{connection.quote(seconds)}, #{quoted_archive}, #{connection.quote(Time.current)}, #{connection.quote(Time.current)})
      SQL
    end

    columns_to_remove.each { |column| remove_column :app_settings, column if column_exists?(:app_settings, column) }
  end

  def restore_to_app_settings
    POLICIES.each_value do |column, _unit, archive_column|
      add_column :app_settings, column, :integer, default: 0, null: false unless column_exists?(:app_settings, column)
      add_column :app_settings, archive_column, :boolean, default: false, null: false if archive_column && !column_exists?(:app_settings, archive_column)
    end

    select_all("SELECT * FROM retention_policy_settings").each do |row|
      definition = POLICIES[row["retention_key"].to_sym]
      next unless definition

      column, unit, archive_column = definition
      value = row["retention_seconds"] ? row["retention_seconds"].to_i / unit_seconds(unit) : 0
      assignments = [ "#{connection.quote_column_name(column)} = #{value}" ]
      assignments << "#{connection.quote_column_name(archive_column)} = #{connection.quote(truthy?(row['archive_before_delete']))}" if archive_column
      execute "UPDATE app_settings SET #{assignments.join(', ')}"
    end
  end

  def columns_to_remove
    POLICIES.values.flat_map { |column, _unit, archive_column| [ column, archive_column ] }.compact.uniq
  end

  def column_default(column)
    connection.columns(:app_settings).find { |candidate| candidate.name == column.to_s }&.default
  end

  def unit_seconds(unit)
    unit == :hours ? 1.hour.to_i : 1.day.to_i
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
