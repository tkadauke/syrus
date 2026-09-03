class AddLastTickedAtToPluginRecords < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:plugin_records)

    unless column_exists?(:plugin_records, :last_ticked_at)
      add_column :plugin_records, :last_ticked_at, :datetime
    end
  end

  def down
    return unless table_exists?(:plugin_records)

    if column_exists?(:plugin_records, :last_ticked_at)
      remove_column :plugin_records, :last_ticked_at
    end
  end
end
