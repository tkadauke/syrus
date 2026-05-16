class AddPendingEpicReferenceToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :pending_epic_reference, :json, null: false, default: {}
  end
end
