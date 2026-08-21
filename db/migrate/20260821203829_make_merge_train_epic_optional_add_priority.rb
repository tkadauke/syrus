class MakeMergeTrainEpicOptionalAddPriority < ActiveRecord::Migration[8.1]
  def up
    change_column_null :merge_trains, :epic_id, true
    add_column :merge_trains, :priority, :string unless column_exists?(:merge_trains, :priority)
  end

  def down
    change_column_null :merge_trains, :epic_id, false
    remove_column :merge_trains, :priority if column_exists?(:merge_trains, :priority)
  end
end
