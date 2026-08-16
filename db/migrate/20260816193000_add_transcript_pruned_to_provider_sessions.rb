class AddTranscriptPrunedToProviderSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_sessions, :transcript_pruned, :boolean, null: false, default: false unless column_exists?(:provider_sessions, :transcript_pruned)
    ProviderSession.reset_column_information
    ProviderSession.where(transcript_jsonl: nil).update_all(transcript_pruned: true)
  end

  def down
    remove_column :provider_sessions, :transcript_pruned if column_exists?(:provider_sessions, :transcript_pruned)
  end
end
