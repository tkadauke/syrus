class RuntimeImageVerificationReevaluationJob < ApplicationJob
  include SkipIfPending
  queue_as :cleanup
  BATCH_SIZE = 25
  def perform(now: Time.current, database_version: ENV["SYRUS_VULNERABILITY_DATABASE_VERSION"])
    policy = RuntimeImages::Verifications::Policy.current
    candidates = RuntimeImageVerificationAttestation.reevaluation_candidates.includes(:attempt, :runtime_image)
      .order(:expires_at).limit(BATCH_SIZE)
    results = RuntimeImageBuildResult.includes(request: :evidences).where(runtime_image_id: candidates.map(&:runtime_image_id)).index_by(&:runtime_image_id)
    reevaluator = RuntimeImages::Verifications::Reevaluator.new
    candidates.each do |attestation|
      result = results[attestation.runtime_image_id]
      next unless reevaluator.due?(attestation, policy: policy, database_version: database_version, now: now, build_result: result)
      reevaluator.call(attestation, policy: policy, now: now, build_result: result)
    rescue StandardError => e
      Rails.logger.warn("[RuntimeImageVerificationReevaluationJob] attestation_id=#{attestation.id} error=#{e.class}")
    end
  end
end
