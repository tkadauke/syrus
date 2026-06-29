class AddProviderTranscriptStorageToClaudeSessions < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:claude_sessions, :raw_provider_transcript)
      add_column :claude_sessions, :raw_provider_transcript, :text
    end
    unless column_exists?(:claude_sessions, :normalized_messages)
      add_column :claude_sessions, :normalized_messages, :json
    end
  end

  def down
    remove_column :claude_sessions, :normalized_messages if column_exists?(:claude_sessions, :normalized_messages)
    if column_exists?(:claude_sessions, :raw_provider_transcript)
      remove_column :claude_sessions, :raw_provider_transcript
    end
  end
end
