class ReleaseStuckEpicBlockedJobs < ActiveRecord::Migration[8.1]
  def up
    Maintenance::ReleaseStuckEpicBlockedJobs.call
  end

  def down; end
end
