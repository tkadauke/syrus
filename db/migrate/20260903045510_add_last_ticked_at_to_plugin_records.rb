class AddLastTickedAtToPluginRecords < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:plugin_records, :last_ticked_at)
      add_column :plugin_records, :last_ticked_at, :datetime
    end
  end

  def down
    if column_exists?(:plugin_records, :last_ticked_at)
      remove_column :plugin_records, :last_ticked_at
    end
  end
end
