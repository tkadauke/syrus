module RuntimeImages
  module Verifications
    class Attestor
      VALIDITY = 24.hours

      # The caller holds the RuntimeImage row lock. That serializes issuance
      # with the eligibility decision and prevents an older attempt finishing
      # late from superseding a newer attestation.
      def issue!(attempt, current:, now: Time.current)
        prior = latest_accepted(attempt.runtime_image)
        attestation = attempt.create_attestation!(attributes(attempt, now).merge(
          invalidated_at: current ? nil : now,
          invalidation_reason: current ? nil : "stale_attempt"
        ))
        return attestation unless current

        supersede_prior!(attestation, now)
        create_revocation_candidate!(attestation, prior, now)
        attestation
      end

      private

      def attributes(attempt, now)
        {
          runtime_image: attempt.runtime_image,
          image_digest: attempt.image_digest,
          policy_digest: attempt.policy_digest,
          evidence_digest: evidence_digest(attempt),
          outcome: attempt.state,
          safe_summary: safe_summary(attempt),
          vulnerability_database_version: attempt.scan_evidence&.database_version,
          issued_at: now,
          expires_at: now + VALIDITY
        }
      end

      def safe_summary(attempt)
        {
          "outcome" => attempt.state,
          "failure_class" => attempt.failure_class,
          "failure_code" => attempt.failure_code,
          "checks" => attempt.checks.map { |check| { "key" => check.verifier_key, "state" => check.state } },
          "supply_chain" => attempt.scan_evidence&.finding_summary,
          "image_policy" => attempt.policy_evidence&.safe_summary
        }.compact
      end

      def evidence_digest(attempt)
        evidence = {
          "checks" => attempt.checks.map { |check| [ check.verifier_key, check.state, check.evidence_references ] },
          "sbom" => attempt.scan_evidence&.sbom_digest,
          "scan_report" => attempt.scan_evidence&.report_digest,
          "policy_report" => attempt.policy_evidence&.report_digest
        }
        CanonicalJson.digest(evidence)
      end

      def latest_accepted(image)
        image.runtime_image_verification_attestations.accepted.joins(:attempt)
          .order("runtime_image_verification_attempts.number DESC").first
      end

      def supersede_prior!(attestation, now)
        RuntimeImageVerificationAttestation.where(runtime_image: attestation.runtime_image, invalidated_at: nil)
          .where.not(id: attestation.id).update_all(invalidated_at: now, invalidation_reason: "superseded", updated_at: now)
      end

      def create_revocation_candidate!(attestation, prior, now)
        return if attestation.outcome == "accepted" || attestation.attempt.failure_class != "policy" || prior.nil?

        RuntimeImageRevocationCandidate.create!(
          runtime_image: attestation.runtime_image,
          prior_attestation: prior,
          triggering_attestation: attestation,
          reason_code: attestation.attempt.failure_code,
          safe_summary: attestation.safe_summary,
          detected_at: now
        )
      end
    end
  end
end
