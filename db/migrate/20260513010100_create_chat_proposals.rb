class CreateChatProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_proposals do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :slug, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :kind, default: "syrus_issue", null: false
      t.string :labels
      t.string :state, default: "pending", null: false
      t.references :job, foreign_key: true
      t.integer :github_issue_number
      t.datetime :filed_at
      t.datetime :discarded_at

      t.timestamps
    end

    add_index :chat_proposals, [ :chat_session_id, :slug ], unique: true
    add_index :chat_proposals, [ :chat_session_id, :state ]
  end
end
