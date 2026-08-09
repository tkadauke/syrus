class CreatePasskeyChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :passkey_challenges, if_not_exists: true do |t|
      t.string :challenge, null: false
      t.integer :user_id
      t.string :challenge_type, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :passkey_challenges, :expires_at unless index_exists?(:passkey_challenges, :expires_at)
    add_index :passkey_challenges, [ :user_id, :challenge_type ] unless index_exists?(:passkey_challenges, [ :user_id, :challenge_type ])
  end
end
