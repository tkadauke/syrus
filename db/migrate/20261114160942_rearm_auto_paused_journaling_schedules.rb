class RearmAutoPausedJournalingSchedules < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE scheduled_tasks
      SET state = 'scheduled', consecutive_failure_count = 0, updated_at = CURRENT_TIMESTAMP
      WHERE system_key = 'journaling' AND state = 'auto_paused'
    SQL
  end

  def down = nil
end
