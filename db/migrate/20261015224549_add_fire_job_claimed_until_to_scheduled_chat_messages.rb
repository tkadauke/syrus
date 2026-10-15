class AddFireJobClaimedUntilToScheduledChatMessages < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:scheduled_chat_messages, :fire_job_claimed_until)
      add_column :scheduled_chat_messages, :fire_job_claimed_until, :datetime
    end

    unless index_exists?(:scheduled_chat_messages, [ :sent_at, :fire_at, :fire_job_claimed_until ])
      add_index :scheduled_chat_messages, [ :sent_at, :fire_at, :fire_job_claimed_until ]
    end
  end
end
