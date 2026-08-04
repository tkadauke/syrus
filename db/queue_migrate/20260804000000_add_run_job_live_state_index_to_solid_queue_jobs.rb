class AddRunJobLiveStateIndexToSolidQueueJobs < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:solid_queue_jobs)
    return if index_exists?(:solid_queue_jobs, [ :class_name, :finished_at, :created_at ], name: "index_solid_queue_jobs_on_class_finished_created_at")

    add_index :solid_queue_jobs,
      [ :class_name, :finished_at, :created_at ],
      name: "index_solid_queue_jobs_on_class_finished_created_at"
  end
end
