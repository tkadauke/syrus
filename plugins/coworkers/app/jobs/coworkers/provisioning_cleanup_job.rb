class Coworkers::ProvisioningCleanupJob < PluginJob
  MAX_ATTEMPTS = PluginJob::DEFAULT_ATTEMPTS

  plugin :coworkers
  queue_as :cleanup
  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    Coworkers::ProvisioningCleanup.call(Coworkers::ProvisioningAttempt.find(attempt_id))
  end
end
