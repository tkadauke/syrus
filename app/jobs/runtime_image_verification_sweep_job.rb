class RuntimeImageVerificationSweepJob < ApplicationJob
  queue_as :runtime_image_builds

  def perform(database_version = nil)
    database_version ||= RuntimeImages::Verifications::SupplyChainScanner.new.current_database_version
    RuntimeImageVerificationReevaluationJob.perform_now(database_version: database_version)
  end
end
