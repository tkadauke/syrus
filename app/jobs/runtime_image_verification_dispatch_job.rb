class RuntimeImageVerificationDispatchJob < ApplicationJob
  queue_as :control_plane

  def perform(database_version = nil)
    RuntimeImageVerificationSweepJob.perform_later(database_version)
  end
end
