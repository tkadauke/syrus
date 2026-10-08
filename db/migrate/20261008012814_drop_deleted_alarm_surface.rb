class DropDeletedAlarmSurface < ActiveRecord::Migration[8.1]
  def up
    drop_table :attention_items, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
