class AddWorkerHealthHostnameObservedIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :worker_host_health_samples,
      [ :hostname, :observed_at ],
      name: "idx_worker_health_hostname_observed",
      if_not_exists: true
  end
end
