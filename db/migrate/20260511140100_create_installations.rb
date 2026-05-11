class CreateInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :installations do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint :github_installation_id, null: false
      t.string :account_login, null: false
      t.bigint :account_id, null: false
      t.string :account_type, null: false
      t.datetime :installed_at, null: false
      t.datetime :removed_at
      t.text :cached_token
      t.datetime :cached_token_expires_at

      t.timestamps
    end

    add_index :installations, :github_installation_id, unique: true
  end
end
