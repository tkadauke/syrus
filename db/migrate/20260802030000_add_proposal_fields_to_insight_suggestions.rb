class AddProposalFieldsToInsightSuggestions < ActiveRecord::Migration[8.1]
  def change
    add_column :insight_suggestions, :proposal_type, :string, null: false, default: "informational"
    add_reference :insight_suggestions, :target_memory, null: true, foreign_key: { to_table: :chat_memories }
    add_reference :insight_suggestions, :target_insight, null: true, foreign_key: { to_table: :insight_suggestions }
    add_column :insight_suggestions, :stale_memory_text, :text
    add_column :insight_suggestions, :stale_memory_evidence, :text

    add_index :insight_suggestions, :proposal_type
  end
end
