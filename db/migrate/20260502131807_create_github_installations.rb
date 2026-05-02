class CreateGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_installations do |t|
      t.integer :user_id, null: false
      t.integer :installation_id, null: false

      t.timestamps
    end

    add_index :github_installations, :user_id, unique: true
    add_index :github_installations, :installation_id, unique: true
    add_foreign_key :github_installations, :users
  end
end
