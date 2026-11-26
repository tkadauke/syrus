class Coworkers::Callbacks
  def self.on_tick
    Coworkers::ProvisioningReconciler.call
    Coworkers::BranchRetentionSweepJob.perform_later
    Coworkers::EnvironmentReconcileJob.perform_later
    Coworkers::Coworker.where(state: "active").find_each { |coworker| Coworkers::SystemSchedules.reconcile!(coworker) }
  end

  def self.on_disable
    Coworkers::Environment.find_each { |environment| Coworkers::EnvironmentLifecycle.new(environment).disable! }
  end
end
