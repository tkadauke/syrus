class AddRollbackProvenanceToJobs < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :rollback_of, null: true, foreign_key: { to_table: :jobs }, index: true
  end
end
