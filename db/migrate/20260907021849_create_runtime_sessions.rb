class CreateRuntimeSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_sessions, if_not_exists: true do |t|
      t.references :repository, null: false
      t.references :chat_session, null: true
      t.references :job, null: true
      t.references :workflow, null: true
      t.references :run, null: true
      t.string :workspace_ref, null: false
      t.string :provider_key, null: false
      t.string :display_name, null: false
      t.string :state, null: false, default: "starting"
      t.boolean :primary, null: false, default: false
      t.json :capabilities, null: false
      t.string :stream_url
      t.string :latest_frame_url
      t.datetime :latest_frame_at
      t.text :last_error
      t.json :metadata, null: false
      t.datetime :expires_at

      t.timestamps
    end

    add_index :runtime_sessions, [ :repository_id, :state ] unless index_exists?(:runtime_sessions, [ :repository_id, :state ])
    add_index :runtime_sessions, :provider_key unless index_exists?(:runtime_sessions, :provider_key)
  end

  def down
    drop_table :runtime_sessions, if_exists: true
  end
end
