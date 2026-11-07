class CreateChatFileAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_file_attachments do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :attachable, polymorphic: true, null: true
      t.string :name, null: false
      t.string :mime_type, null: false
      t.bigint :byte_size, null: false
      t.string :checksum, null: false
      t.timestamps
    end
    add_index :chat_file_attachments, [ :chat_session_id, :attachable_type, :attachable_id ], name: "idx_chat_file_attachments_owner"
  end
end
