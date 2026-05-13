class MakeClaudeSessionsPolymorphic < ActiveRecord::Migration[8.1]
  def up
    add_reference :claude_sessions, :resumable, polymorphic: true, index: { unique: true }
    change_column_null :claude_sessions, :run_id, true

    execute <<~SQL.squish
      UPDATE claude_sessions
      SET resumable_type = 'Run', resumable_id = run_id
      WHERE run_id IS NOT NULL
        AND (resumable_type IS NULL OR resumable_id IS NULL)
    SQL
  end

  def down
    remove_reference :claude_sessions, :resumable, polymorphic: true, index: { unique: true }
    change_column_null :claude_sessions, :run_id, false
  end
end
