class AddHiddenAtToChatParticipants < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:chat_participants)
      create_table :chat_participants do |t|
        t.references :chat_session, null: false
        t.references :user, null: false
        t.string :role, null: false, default: "member"
        t.datetime :joined_at, null: false
        t.datetime :last_read_at
        t.timestamps
      end
      unless index_exists?(:chat_participants, [ :chat_session_id, :user_id ])
        add_index :chat_participants, [ :chat_session_id, :user_id ], unique: true
      end
      unless index_exists?(:chat_participants, [ :user_id, :chat_session_id ], name: "idx_chat_participants_user_session")
        add_index :chat_participants, [ :user_id, :chat_session_id ], name: "idx_chat_participants_user_session"
      end
    end

    add_column :chat_participants, :hidden_at, :datetime unless column_exists?(:chat_participants, :hidden_at)
    add_index :chat_participants, [ :user_id, :hidden_at ] unless index_exists?(:chat_participants, [ :user_id, :hidden_at ])

    execute <<~SQL.squish
      UPDATE chat_participants
      SET hidden_at = (
        SELECT chat_sessions.hidden_at
        FROM chat_sessions
        WHERE chat_sessions.id = chat_participants.chat_session_id
      )
      WHERE role = 'owner'
        AND EXISTS (
          SELECT 1
          FROM chat_sessions
          WHERE chat_sessions.id = chat_participants.chat_session_id
            AND chat_sessions.hidden_at IS NOT NULL
        )
    SQL
  end

  def down
    remove_column :chat_participants, :hidden_at if column_exists?(:chat_participants, :hidden_at)
  end
end
