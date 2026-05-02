class AddLastHeartbeatAtToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :last_heartbeat_at, :datetime
    add_index :runs, [ :state, :last_heartbeat_at ]
  end
end
