class HealthCheckJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(message = "alive")
    Rails.logger.info("[HealthCheckJob] #{message} at #{Time.current.iso8601}")
  end
end
