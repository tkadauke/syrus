class CreateMainConcernReports < ActiveRecord::Migration[8.1]
  def change
    create_table :main_concern_reports, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :job, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.references :run, null: false, foreign_key: true
      t.text :reason, null: false
      t.json :failing_tests

      t.timestamps
    end

    add_index :main_concern_reports, [ :repository_id, :created_at ],
              name: "index_main_concern_reports_on_repository_id_and_created_at" \
              unless index_exists?(:main_concern_reports, [ :repository_id, :created_at ],
                                   name: "index_main_concern_reports_on_repository_id_and_created_at")
  end
end
