class AddCanonicalJobToJobs < ActiveRecord::Migration[8.1]
  def up
    add_reference :jobs, :canonical_job, null: true, foreign_key: false unless column_exists?(:jobs, :canonical_job_id)
  end

  def down
    remove_reference :jobs, :canonical_job if column_exists?(:jobs, :canonical_job_id)
  end
end
