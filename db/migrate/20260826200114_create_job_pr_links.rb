class CreateJobPrLinks < ActiveRecord::Migration[8.1]
  def up
    create_table :job_pr_links, if_not_exists: true do |t|
      t.references :job, null: false
      t.string :role, null: false, limit: 32
      t.bigint :source_repository_id
      t.string :source_ref
      t.bigint :target_repository_id
      t.string :target_ref
      t.integer :pr_number
      t.json :metadata

      t.timestamps
    end

    unless index_exists?(:job_pr_links, [ :job_id, :role ])
      add_index :job_pr_links, [ :job_id, :role ], unique: true,
        name: "index_job_pr_links_on_job_id_and_role"
    end
    add_index :job_pr_links, :source_repository_id unless index_exists?(:job_pr_links, :source_repository_id)
    add_index :job_pr_links, :target_repository_id unless index_exists?(:job_pr_links, :target_repository_id)
  end

  def down
    drop_table :job_pr_links, if_exists: true
  end
end
