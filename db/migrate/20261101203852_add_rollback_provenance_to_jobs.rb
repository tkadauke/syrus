class AddRollbackProvenanceToJobs < ActiveRecord::Migration[8.1]
  def change
    add_reference :jobs, :rollback_of, null: true, index: false unless column_exists?(:jobs, :rollback_of_id)
    add_index :jobs, :rollback_of_id unless index_exists?(:jobs, :rollback_of_id)
  end
end
