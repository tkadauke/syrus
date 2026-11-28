class AddFiledByCoworkerToJobs < ActiveRecord::Migration[8.1]
  def up
    add_reference :jobs, :filed_by_coworker, null: true, index: false, foreign_key: false unless column_exists?(:jobs, :filed_by_coworker_id)
    add_index :jobs, :filed_by_coworker_id unless index_exists?(:jobs, :filed_by_coworker_id)
  end

  def down
    remove_index :jobs, :filed_by_coworker_id if index_exists?(:jobs, :filed_by_coworker_id)
    remove_reference :jobs, :filed_by_coworker, index: false, foreign_key: false if column_exists?(:jobs, :filed_by_coworker_id)
  end
end
