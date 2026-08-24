class CreateGithubCollaboratorDiscrepancies < ActiveRecord::Migration[8.1]
  def change
    create_table :github_collaborator_discrepancies, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :github_login, null: false
      t.string :github_permission, null: false
      t.datetime :checked_at, null: false

      t.timestamps
    end

    unless index_exists?(:github_collaborator_discrepancies, [ :repository_id, :github_login ])
      add_index :github_collaborator_discrepancies, [ :repository_id, :github_login ], unique: true, name: "index_github_collab_discrepancies_on_repo_id_and_login"
    end
  end
end
