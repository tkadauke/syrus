class AddRelayStartedAtToTerminalSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :terminal_sessions, :relay_started_at, :datetime unless column_exists?(:terminal_sessions, :relay_started_at)
  end

  def down
    remove_column :terminal_sessions, :relay_started_at if column_exists?(:terminal_sessions, :relay_started_at)
  end
end
