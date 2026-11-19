class Coworkers::ProvisioningCleanupJob < PluginJob
  plugin :coworkers
  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    Coworkers::ProvisioningCleanup.call(Coworkers::ProvisioningAttempt.find(attempt_id))
  end
end
