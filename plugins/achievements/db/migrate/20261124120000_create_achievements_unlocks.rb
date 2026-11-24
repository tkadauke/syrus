class CreateAchievementsUnlocks < ActiveRecord::Migration[8.1]
  def up
    create_table :achievements_unlocks, if_not_exists: true do |t|
      t.string :definition_key, null: false
      t.integer :definition_version, null: false
      t.string :scope, null: false
      # "instance" or "user:<id>"; a string so uniqueness holds on MySQL, where
      # NULLs never collide in a unique index.
      t.string :owner_key, null: false
      t.bigint :user_id
      t.string :subject_type
      t.bigint :subject_id
      t.json :evidence
      t.datetime :unlocked_at, null: false
      t.timestamps
    end
    add_index :achievements_unlocks, [:definition_key, :owner_key], unique: true,
      name: "idx_achievements_unlocks_definition_owner" unless index_exists?(:achievements_unlocks, [:definition_key, :owner_key], name: "idx_achievements_unlocks_definition_owner")
    add_index :achievements_unlocks, :user_id unless index_exists?(:achievements_unlocks, :user_id)
    add_index :achievements_unlocks, [:subject_type, :subject_id], name: "idx_achievements_unlocks_subject" unless index_exists?(:achievements_unlocks, [:subject_type, :subject_id], name: "idx_achievements_unlocks_subject")

    create_table :achievements_acknowledgments, if_not_exists: true do |t|
      t.bigint :unlock_id, null: false
      t.bigint :user_id, null: false
      t.datetime :acknowledged_at, null: false
      t.timestamps
    end
    add_index :achievements_acknowledgments, [:unlock_id, :user_id], unique: true,
      name: "idx_achievements_acks_unlock_user" unless index_exists?(:achievements_acknowledgments, [:unlock_id, :user_id], name: "idx_achievements_acks_unlock_user")
    add_index :achievements_acknowledgments, :user_id unless index_exists?(:achievements_acknowledgments, :user_id)
  end

  def down
    drop_table :achievements_acknowledgments, if_exists: true
    drop_table :achievements_unlocks, if_exists: true
  end
end
