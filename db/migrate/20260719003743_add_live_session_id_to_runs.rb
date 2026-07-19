class AddLiveSessionIdToRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :runs, :live_session_id, :string unless column_exists?(:runs, :live_session_id)
  end

  def down
    remove_column :runs, :live_session_id if column_exists?(:runs, :live_session_id)
  end
end
