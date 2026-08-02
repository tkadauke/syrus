class AddProposalFieldsToInsightSuggestions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:insight_suggestions, :proposal_type)
      add_column :insight_suggestions, :proposal_type, :string, null: false, default: "informational"
    end

    unless column_exists?(:insight_suggestions, :target_memory_id)
      add_reference :insight_suggestions, :target_memory, null: true, foreign_key: { to_table: :chat_memories }
    end

    unless column_exists?(:insight_suggestions, :target_insight_id)
      add_reference :insight_suggestions, :target_insight, null: true, foreign_key: { to_table: :insight_suggestions }
    end

    add_column :insight_suggestions, :stale_memory_text, :text unless column_exists?(:insight_suggestions, :stale_memory_text)
    add_column :insight_suggestions, :stale_memory_evidence, :text unless column_exists?(:insight_suggestions, :stale_memory_evidence)

    add_index :insight_suggestions, :proposal_type unless index_exists?(:insight_suggestions, :proposal_type)
  end
end
