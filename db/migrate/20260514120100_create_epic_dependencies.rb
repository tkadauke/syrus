class CreateEpicDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :epic_dependencies do |t|
      t.references :epic, null: false, foreign_key: true
      t.references :depends_on_epic, null: false, foreign_key: { to_table: :epics }
      t.boolean :derived, default: false, null: false

      t.timestamps
    end

    add_index :epic_dependencies,
              [ :epic_id, :depends_on_epic_id, :derived ],
              unique: true,
              name: "index_epic_deps_on_epic_and_depends_on_and_derived"
  end
end
