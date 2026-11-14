class AddProposerToJobsAndEpics < ActiveRecord::Migration[8.1]
  def up
    add_reference :jobs, :proposer, polymorphic: true unless column_exists?(:jobs, :proposer_id)
    add_reference :epics, :proposer, polymorphic: true unless column_exists?(:epics, :proposer_id)
  end

  def down
    remove_reference :jobs, :proposer, polymorphic: true if column_exists?(:jobs, :proposer_id)
    remove_reference :epics, :proposer, polymorphic: true if column_exists?(:epics, :proposer_id)
  end
end
