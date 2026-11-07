class CreateChatFileAttachments < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_file_attachments, if_not_exists: true do |t|
      t.references :chat_session, null: false
      t.references :attachable, polymorphic: true, null: true
      t.string :name, null: false
      t.string :mime_type, null: false
      t.bigint :byte_size, null: false
      t.string :checksum, null: false
      t.timestamps
    end
    unless index_exists?(:chat_file_attachments, [ :chat_session_id, :attachable_type, :attachable_id ], name: "idx_chat_file_attachments_owner")
      add_index :chat_file_attachments, [ :chat_session_id, :attachable_type, :attachable_id ], name: "idx_chat_file_attachments_owner"
    end
  end

  def down
    drop_table :chat_file_attachments, if_exists: true
  end
end
