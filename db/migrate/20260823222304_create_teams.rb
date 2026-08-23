class CreateTeams < ActiveRecord::Migration[8.1]
  def change
    create_table :teams, if_not_exists: true do |t|
      t.string :name, null: false

      t.timestamps
    end
  end
end
