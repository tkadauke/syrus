class AddWorkerHealthRoleObservedIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :worker_host_health_samples,
      [ :role, :observed_at, :hostname ],
      name: "idx_worker_health_role_observed_host",
      if_not_exists: true
  end
end
