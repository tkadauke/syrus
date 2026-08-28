class AddIndexToJobsOnLandingQueueCachedAt < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:jobs, [ :landing_queue_cached_at, :state ], name: "index_jobs_on_landing_queue_cached_at_and_state")
      add_index :jobs, [ :landing_queue_cached_at, :state ], name: "index_jobs_on_landing_queue_cached_at_and_state"
    end
  end
end
