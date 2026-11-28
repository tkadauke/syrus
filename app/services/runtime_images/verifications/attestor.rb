module RuntimeImages
  module Verifications
    class Attestor
      VALIDITY = 24.hours

      def issue!(attempt, now: Time.current)
        summary = safe_summary(attempt)
        attestation = attempt.create_attestation!(
          runtime_image: attempt.runtime_image, image_digest: attempt.image_digest,
          policy_digest: attempt.policy_digest, evidence_digest: evidence_digest(attempt),
          outcome: attempt.state, safe_summary: summary,
          vulnerability_database_version: attempt.scan_evidence&.database_version,
          issued_at: now, expires_at: now + VALIDITY
        )
        supersede_prior!(attestation, now)
        create_revocation_candidate!(attestation, now)
        attestation
      end

      private

      def safe_summary(attempt)
        {
          "outcome" => attempt.state,
          "failure_class" => attempt.failure_class,
          "failure_code" => attempt.failure_code,
          "checks" => attempt.checks.order(:position).map { |check| { "key" => check.verifier_key, "state" => check.state } },
          "supply_chain" => attempt.scan_evidence&.finding_summary,
          "image_policy" => attempt.policy_evidence&.safe_summary
        }.compact
      end

      def evidence_digest(attempt)
        references = attempt.checks.order(:position).map { |check| [ check.verifier_key, check.state, check.evidence_references ] }
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(references))}"
      end

      def supersede_prior!(attestation, now)
        RuntimeImageVerificationAttestation.where(runtime_image: attestation.runtime_image, invalidated_at: nil)
          .where.not(id: attestation.id).update_all(invalidated_at: now, invalidation_reason: "superseded", updated_at: now)
      end

      def create_revocation_candidate!(attestation, now)
        return if attestation.outcome == "accepted"
        return unless attestation.attempt.failure_class == "policy"

        prior = RuntimeImageVerificationAttestation.where(runtime_image: attestation.runtime_image, outcome: "accepted")
          .where.not(id: attestation.id).order(issued_at: :desc).first
        return unless prior

        RuntimeImageRevocationCandidate.create!(runtime_image: attestation.runtime_image, prior_attestation: prior,
          triggering_attestation: attestation, reason_code: attestation.attempt.failure_code,
          safe_summary: attestation.safe_summary, detected_at: now)
      end
    end
  end
end
