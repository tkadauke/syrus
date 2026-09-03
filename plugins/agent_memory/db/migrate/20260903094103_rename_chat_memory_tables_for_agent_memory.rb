class RenameChatMemoryTablesForAgentMemory < ActiveRecord::Migration[8.1]
  RENAMES = {
    chat_memories: :agent_memory_entries,
    chat_memory_audit_events: :agent_memory_audit_events
  }.freeze

  def up
    RENAMES.each do |from, to|
      rename_table from, to if table_exists?(from) && !table_exists?(to)
    end

    if column_exists?(:agent_memory_audit_events, :chat_memory_id) && !column_exists?(:agent_memory_audit_events, :entry_id)
      rename_column :agent_memory_audit_events, :chat_memory_id, :entry_id
    end

    # Written by nothing and read by nothing: a vector column added for a
    # semantic-search path that was never built.
    remove_column :agent_memory_entries, :embedding if column_exists?(:agent_memory_entries, :embedding)
  end

  def down
    add_column :agent_memory_entries, :embedding, :binary unless column_exists?(:agent_memory_entries, :embedding)

    if column_exists?(:agent_memory_audit_events, :entry_id) && !column_exists?(:agent_memory_audit_events, :chat_memory_id)
      rename_column :agent_memory_audit_events, :entry_id, :chat_memory_id
    end

    RENAMES.each do |from, to|
      rename_table to, from if table_exists?(to) && !table_exists?(from)
    end
  end
end
