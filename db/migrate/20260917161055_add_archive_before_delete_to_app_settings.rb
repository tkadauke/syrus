class AddArchiveBeforeDeleteToAppSettings < ActiveRecord::Migration[8.1]
  # Off (false) for every table until an operator explicitly enables it.
  # See RetentionPolicyRegistry's `archivable` flag for which tables these
  # columns exist for.
  COLUMNS = %i[
    run_diagnostic_archive_before_delete
    work_engine_reconciler_activity_archive_before_delete
    provider_session_archive_before_delete
    run_health_snapshot_archive_before_delete
    main_branch_health_check_archive_before_delete
  ].freeze

  def up
    COLUMNS.each do |column|
      next if column_exists?(:app_settings, column)

      add_column :app_settings, column, :boolean, default: false, null: false
    end
  end

  def down
    COLUMNS.each do |column|
      remove_column :app_settings, column if column_exists?(:app_settings, column)
    end
  end
end
