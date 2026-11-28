class RuntimeImageVerificationReevaluationJob < ApplicationJob
  queue_as :runtime_image_builds

  BATCH_SIZE = 25

  def perform
    policy = RuntimeImages::Verifications::Policy.current
    database_version = current_database_version
    reevaluator = RuntimeImages::Verifications::Reevaluator.new
    candidates = RuntimeImageVerificationAttestation.reevaluation_candidates
      .includes(:attempt).order(:expires_at, :id).limit(BATCH_SIZE * 4)
    build_results = RuntimeImageBuildResult.where(runtime_image_id: candidates.map(&:runtime_image_id))
      .includes(request: :evidences).index_by(&:runtime_image_id)
    candidates.select { |attestation|
      reevaluator.due?(attestation, policy: policy, database_version: database_version,
        build_result: build_results[attestation.runtime_image_id])
    }
      .first(BATCH_SIZE).each do |attestation|
        reevaluator.call(attestation, policy: policy, database_version: database_version,
          build_result: build_results[attestation.runtime_image_id])
      rescue StandardError => e
        Rails.logger.error("[RuntimeImageVerificationReevaluationJob] attestation_id=#{attestation.id} error=#{e.class}: #{e.message}")
      end
  end

  private

  def current_database_version
    RuntimeImages::Verifications::SupplyChainScanner.new.current_database_version
  rescue RuntimeImages::ProviderError, Timeout::Error, SystemCallError => e
    Rails.logger.warn("[RuntimeImageVerificationReevaluationJob] scanner identity unavailable: #{e.class}: #{e.message}")
    nil
  end
end
