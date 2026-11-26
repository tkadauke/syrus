class RuntimeImageVerificationSweepJob < ApplicationJob
  queue_as :runtime_image_builds

  def perform(database_version = nil)
    database_version ||= RuntimeImages::Verifications::SupplyChainScanner.new.current_database_version
    RuntimeImage.where(availability: "available").find_each do |image|
      RuntimeImages::Verifications::Reevaluator.new.call(image, database_version: database_version)
    rescue RuntimeImages::Error, ActiveRecord::ActiveRecordError => e
      RuntimeImages::Audit.record("verification.reevaluation_failed", outcome: :failed, image: image,
                                  details: { error_class: e.class.name, error: e.message })
    end
  end
end
