class CreateJobApprovals < ActiveRecord::Migration[8.1]
  def up
    create_table :job_approvals, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :approved_at, null: false
      t.timestamps
    end
    unless index_exists?(:job_approvals, [ :job_id, :user_id ])
      add_index :job_approvals, [ :job_id, :user_id ], unique: true,
        name: "index_job_approvals_on_job_id_and_user_id"
    end
  end

  def down
    drop_table :job_approvals, if_exists: true
  end
end
