class CreateChatAttachments < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_attachments do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :attachable, polymorphic: true, null: false
      t.datetime :attached_at, null: false

      t.timestamps
    end

    add_index :chat_attachments,
              [ :chat_session_id, :attachable_type, :attachable_id ],
              unique: true,
              name: "index_chat_attachments_on_session_and_attachable"

    execute <<~SQL.squish
      INSERT INTO chat_attachments
        (chat_session_id, attachable_type, attachable_id, attached_at, created_at, updated_at)
      SELECT id, 'Repository', repository_id, created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM chat_sessions
      WHERE repository_id IS NOT NULL
    SQL

    remove_index :chat_sessions,
                 name: "index_chat_sessions_on_repository_id_and_last_message_at",
                 if_exists: true
    remove_reference :chat_sessions, :repository, foreign_key: true, index: true
  end

  def down
    add_reference :chat_sessions, :repository, foreign_key: true, index: true
    add_index :chat_sessions, [ :repository_id, :last_message_at ]

    execute <<~SQL.squish
      UPDATE chat_sessions
      SET repository_id = (
        SELECT attachable_id
        FROM chat_attachments
        WHERE chat_attachments.chat_session_id = chat_sessions.id
          AND chat_attachments.attachable_type = 'Repository'
        ORDER BY attached_at ASC, id ASC
        LIMIT 1
      )
    SQL

    change_column_null :chat_sessions, :repository_id, false
    drop_table :chat_attachments
  end
end
