class Coworkers::ProvisioningCleanupJob < PluginJob
  plugin_name "coworkers"
  queue_as :cleanup
  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    Coworkers::ProvisioningCleanup.call(Coworkers::ProvisioningAttempt.find(attempt_id))
  end
end
