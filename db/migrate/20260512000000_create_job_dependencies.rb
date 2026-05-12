class CreateJobDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :job_dependencies do |t|
      t.references :job, null: false, foreign_key: true
      t.references :depends_on_job, null: false, foreign_key: { to_table: :jobs }
      t.string :source, null: false
      t.references :created_by_user, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :job_dependencies, [ :job_id, :depends_on_job_id ], unique: true
  end
end
