class ClearSupervisorSystemKindFromChatSessions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE chat_sessions
      SET system_kind = NULL,
          pinned = FALSE,
          hidden_at = NULL
      WHERE system_kind = 'supervisor'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
