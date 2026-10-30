class Coworkers::ProvisioningCleanupJob < ApplicationJob
  MAX_ATTEMPTS = 5
  queue_as :cleanup
  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS
  discard_on ActiveRecord::RecordNotFound

  def perform(attempt_id)
    Coworkers::ProvisioningCleanup.call(Coworkers::ProvisioningAttempt.find(attempt_id))
  end
end
