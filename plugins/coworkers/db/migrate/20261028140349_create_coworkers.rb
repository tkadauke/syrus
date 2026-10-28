class CreateCoworkers < ActiveRecord::Migration[8.1]
  def up
    create_table :coworkers, if_not_exists: true do |t|
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :handle, null: false
      t.string :chat_provider
      t.string :chat_model
      t.string :chat_effort
      t.string :state, null: false, default: "active"
      t.string :workspace_repo, null: false
      t.string :color_key, null: false
      t.string :avatar_key
      t.string :role_summary
      t.timestamps
    end
    add_index :coworkers, :handle, unique: true unless index_exists?(:coworkers, :handle, unique: true)

    create_table :coworker_grants, if_not_exists: true do |t|
      t.references :coworker, null: false, foreign_key: true
      t.string :capability, null: false
      t.json :constraints, null: false
      t.string :approval_policy, null: false
      t.timestamps
    end
    add_index :coworker_grants, [ :coworker_id, :capability ], unique: true unless index_exists?(:coworker_grants, [ :coworker_id, :capability ], unique: true)

    create_table :coworker_chats, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true, index: false
      t.references :coworker, null: false, foreign_key: true, index: false
      t.string :role, null: false
      t.timestamps
    end
    add_index :coworker_chats, :chat_session_id, unique: true unless index_exists?(:coworker_chats, :chat_session_id, unique: true)
    add_index :coworker_chats, :coworker_id, unique: true, where: "role = 'main'", name: "index_coworker_chats_one_main" unless index_exists?(:coworker_chats, :coworker_id, name: "index_coworker_chats_one_main")
  end

  def down
    drop_table :coworker_chats, if_exists: true
    drop_table :coworker_grants, if_exists: true
    drop_table :coworkers, if_exists: true
  end
end
