class CreateTeamRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :team_repositories, if_not_exists: true do |t|
      t.references :team, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      t.string :role, null: false

      t.timestamps
    end

    add_index :team_repositories, [ :team_id, :repository_id ], unique: true, name: "index_team_repositories_on_team_id_and_repository_id" unless index_exists?(:team_repositories, [ :team_id, :repository_id ])
  end
end
