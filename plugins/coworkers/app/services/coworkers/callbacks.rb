class Coworkers::Callbacks
  def self.on_tick
    Coworkers::ProvisioningReconciler.call
  end
end
