class CreateChatBridgeThreads < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:chat_bridge_threads)
      create_table :chat_bridge_threads do |t|
        t.references :origin_chat_session, null: false
        t.references :target_chat_session, null: false
        t.references :opened_by_user, null: false
        t.string :state, null: false, default: "open"
        t.integer :hop_count, null: false, default: 0
        t.integer :max_hops, null: false, default: 6

        t.timestamps
      end
    end

    unless foreign_key_exists?(:chat_bridge_threads, :chat_sessions, column: :origin_chat_session_id)
      add_foreign_key :chat_bridge_threads, :chat_sessions, column: :origin_chat_session_id
    end

    unless foreign_key_exists?(:chat_bridge_threads, :chat_sessions, column: :target_chat_session_id)
      add_foreign_key :chat_bridge_threads, :chat_sessions, column: :target_chat_session_id
    end

    unless foreign_key_exists?(:chat_bridge_threads, :users, column: :opened_by_user_id)
      add_foreign_key :chat_bridge_threads, :users, column: :opened_by_user_id
    end

    unless index_exists?(:chat_bridge_threads, [ :origin_chat_session_id, :state ], name: "idx_chat_bridge_threads_origin_state")
      add_index :chat_bridge_threads, [ :origin_chat_session_id, :state ], name: "idx_chat_bridge_threads_origin_state"
    end

    unless index_exists?(:chat_bridge_threads, [ :target_chat_session_id, :state ], name: "idx_chat_bridge_threads_target_state")
      add_index :chat_bridge_threads, [ :target_chat_session_id, :state ], name: "idx_chat_bridge_threads_target_state"
    end
  end
end
