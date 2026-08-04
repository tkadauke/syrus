class CreateGithubAuthFallbackDiagnostics < ActiveRecord::Migration[8.1]
  def change
    create_table :github_auth_fallback_diagnostics do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :installation, null: true, foreign_key: true
      t.references :run, null: true, foreign_key: true
      t.bigint :github_installation_id
      t.string :operation_type, null: false
      t.string :error_class, null: false
      t.integer :error_status
      t.text :error_message
      t.boolean :refresh_attempted, null: false, default: false
      t.boolean :refresh_succeeded, null: false, default: false

      t.timestamps
    end

    add_index :github_auth_fallback_diagnostics, [ :repository_id, :created_at ], name: "index_github_auth_fallbacks_on_repository_and_created_at"
    add_index :github_auth_fallback_diagnostics, [ :installation_id, :created_at ], name: "index_github_auth_fallbacks_on_installation_and_created_at"
  end
end
