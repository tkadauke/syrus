class CreateTeamMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :team_memberships, if_not_exists: true do |t|
      t.references :team, null: false
      t.references :user, null: false
      t.string :role, null: false

      t.timestamps
    end

    add_index :team_memberships, [ :team_id, :user_id ], unique: true, name: "index_team_memberships_on_team_id_and_user_id" unless index_exists?(:team_memberships, [ :team_id, :user_id ])
  end
end
