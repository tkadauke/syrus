class Coworkers::Callbacks
  def self.on_tick
    Coworkers::ProvisioningReconciler.call
    Coworkers::BranchRetentionSweepJob.perform_later
    Coworkers::Coworker.where(state: "active").find_each { |coworker| Coworkers::SystemSchedules.reconcile!(coworker) }
  end
end
