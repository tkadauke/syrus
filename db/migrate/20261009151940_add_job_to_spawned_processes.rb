class AddJobToSpawnedProcesses < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:spawned_processes, :job_id)
      add_reference :spawned_processes, :job, null: true
    end
  end

  def down
    remove_reference :spawned_processes, :job if column_exists?(:spawned_processes, :job_id)
  end
end
