class CreateChatGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_goals do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :repository, foreign_key: true
      t.text :prompt, null: false
      t.text :completion_condition
      t.json :mode_snapshot, null: false
      t.string :status, null: false, default: "active"
      t.string :approval_policy, null: false, default: "manual"
      t.boolean :auto_file_proposals, null: false, default: false
      t.boolean :auto_submit_jobs, null: false, default: false
      t.integer :iteration_count, null: false, default: 0
      t.datetime :terminal_at
      t.string :terminal_reason
      t.json :terminal_details
      t.string :active_slot
      t.timestamps

      t.index [ :chat_session_id, :active_slot ], unique: true
      t.index [ :chat_session_id, :status ]
      t.index [ :user_id, :status ]
    end
  end
end
