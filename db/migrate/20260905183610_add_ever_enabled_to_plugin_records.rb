class AddEverEnabledToPluginRecords < ActiveRecord::Migration[8.1]
  # Whether a plugin has ever been switched on here.
  #
  # `always` effects exist so disabling a plugin does not orphan the rows it
  # already wrote -- a deleted repository still has to take them with it. A
  # plugin that has never been enabled wrote no rows, so it has nothing to
  # clean up, and running its cleanup would load its models for no reason.
  #
  # Every existing record is backfilled true, not just the enabled ones. We
  # cannot tell from here whether a plugin that is off today was ever on and
  # left rows behind, and getting that wrong means its cleanup silently stops
  # running -- an orphaned row costs more than one cleanup effect installed
  # for nothing. Records created after this point start false and get the
  # benefit honestly.
  def up
    return unless table_exists?(:plugin_records)

    unless column_exists?(:plugin_records, :ever_enabled)
      add_column :plugin_records, :ever_enabled, :boolean, default: false, null: false
    end

    execute "UPDATE plugin_records SET ever_enabled = #{quoted_true}"
  end

  def down
    return unless table_exists?(:plugin_records)

    remove_column :plugin_records, :ever_enabled if column_exists?(:plugin_records, :ever_enabled)
  end

  private

  def quoted_true
    connection.quote(ActiveRecord::Type::Boolean.new.serialize(true))
  end
end
