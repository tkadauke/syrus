class CreateChatShellCommands < ActiveRecord::Migration[8.1]
  # One row per one-shot `!` shell command run against a Coding Mode chat
  # session's persistent ChatWorkspace checkout. Mirrors SpawnedProcess's
  # nullable-outcome-plus-finished_at shape rather than a running/succeeded/
  # failed state column, since the actual process lifecycle is tracked by the
  # SpawnedProcess row this references.
  def change
    create_table :chat_shell_commands, if_not_exists: true do |t|
      # Indexed references without database-level constraints: Syrus keeps
      # referential behavior in application code (see CLAUDE.md).
      t.references :chat_session, null: false
      t.references :user, null: false
      t.references :spawned_process, null: true
      t.text :command, null: false
      t.text :output
      t.string :outcome, limit: 32
      t.integer :exit_status
      t.datetime :started_at, null: false
      t.datetime :finished_at

      t.timestamps
    end

    unless index_exists?(:chat_shell_commands, [ :chat_session_id, :finished_at ], name: "idx_chat_shell_commands_session_in_flight")
      add_index :chat_shell_commands, [ :chat_session_id, :finished_at ], name: "idx_chat_shell_commands_session_in_flight"
    end
  end
end
