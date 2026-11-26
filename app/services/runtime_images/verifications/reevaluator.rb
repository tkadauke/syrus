module RuntimeImages
  module Verifications
    # Re-scans immutable candidates when their attestation expires, policy
    # changes, or the caller observes a new vulnerability database revision.
    class Reevaluator
      def initialize(orchestrator: Orchestrator.new, policy: Policy.current, now: Time.current)
        @orchestrator = orchestrator
        @policy = policy
        @now = now
      end

      def call(image, database_version: nil)
        previous = image.runtime_image_verification_attempts.order(number: :desc).first
        trigger = trigger_for(previous, database_version)
        return unless trigger

        attempt = @orchestrator.verify(image, policy: @policy, now: @now)
        emit_revocation_candidate(image, attempt, trigger) if image.available? && attempt.state == "rejected"
        Audit.record("verification.reevaluated", outcome: attempt.accepted? ? :ok : :detected, image: image,
                     details: { trigger: trigger, attempt_id: attempt.id, decision: attempt.decision })
        attempt
      end

      private

      def trigger_for(attempt, database_version)
        return "attestation_expired" if attempt.nil?
        if attempt.accepted? && (attempt.expires_at.nil? || attempt.expires_at <= @now)
          return "attestation_expired"
        end
        return "policy_changed" if attempt.policy_digest != Policy.digest(@policy)
        return unless database_version.present? && attempt.scan_evidence&.database_version != database_version

        "vulnerability_data_changed"
      end

      def emit_revocation_candidate(image, attempt, trigger)
        severity = severe_vulnerability_severity(attempt)
        return unless severity

        RuntimeImageRevocationCandidate.create!(runtime_image: image, attempt: attempt, trigger_kind: trigger,
                                                severity: severity, state: "open", detected_at: @now,
                                                reason: "Re-verification found a newly blocking #{severity}-severity vulnerability.")
        Audit.record("verification.revocation_candidate", outcome: :detected, image: image,
                     details: { trigger: trigger, severity: severity, attempt_id: attempt.id })
      end

      def severe_vulnerability_severity(attempt)
        summary = attempt.scan_evidence&.finding_summary || {}
        blocked = Hash(summary["blocked_vulnerability_severities"])
        return "critical" if blocked.fetch("critical", 0).to_i.positive?
        "high" if blocked.fetch("high", 0).to_i.positive?
      end
    end
  end
end
