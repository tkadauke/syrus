class RuntimeImageVerificationReevaluationJob < ApplicationJob
  queue_as :runtime_image_builds

  BATCH_SIZE = 25

  def perform
    policy = RuntimeImages::Verifications::Policy.current
    candidates = RuntimeImageVerificationAttestation.reevaluation_candidates.includes(:attempt).order(:expires_at).limit(BATCH_SIZE * 4)
    candidates.select { |attestation| due?(attestation, policy) }.first(BATCH_SIZE).each do |attestation|
      RuntimeImages::Verifications::Reevaluator.new.call(attestation, policy: policy)
    rescue StandardError => e
      Rails.logger.error("[RuntimeImageVerificationReevaluationJob] attestation_id=#{attestation.id} error=#{e.class}: #{e.message}")
    end
  end

  private

  def due?(attestation, policy)
    return true if attestation.expires_at <= Time.current

    updated = attestation.attempt.policy_snapshot.deep_merge(policy.except("checks"))
    attestation.policy_digest != "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(updated)))}"
  end

  def canonical(value)
    return value.stringify_keys.sort.to_h { |key, item| [ key, canonical(item) ] } if value.is_a?(Hash)
    return value.map { |item| canonical(item) } if value.is_a?(Array)
    value
  end
end
