module RuntimeImages
  module Verifications
    class Reevaluator
      STALE_ATTEMPT_AFTER = 1.hour
      def initialize(orchestrator: Orchestrator.new, build_runner: Builds::Runner.new)
        @orchestrator, @build_runner = orchestrator, build_runner
      end
      def due?(attestation, policy:, database_version:, now: Time.current, build_result: nil)
        return true if attestation.expires_at <= now
        return true if database_version.present? && attestation.vulnerability_database_version != database_version
        attestation.policy_digest != CanonicalJson.digest(effective_policy(attestation, policy, build_result))
      end
      def call(attestation, policy:, now: Time.current, build_result: nil)
        return attestation unless claim(attestation, now)
        return @orchestrator.verify(attestation.runtime_image, policy: policy, now: now) unless build_result
        evidence = build_result.request.evidences.max_by { |item| [ item.created_at, item.id ] }
        raise ProviderError, "build evidence is unavailable for re-evaluation" unless evidence
        @build_runner.verify_candidate(build_result.request, attestation.runtime_image, evidence, policy: policy)
      end
      private
      def effective_policy(attestation, policy, build_result)
        build_result ? @build_runner.verification_policy(build_result.request, base_policy: policy) : policy
      end
      def claim(attestation, now)
        image = attestation.runtime_image
        image.with_lock do
          attestation.reload
          return false if attestation.invalidated_at?
          latest = image.runtime_image_verification_attempts.order(number: :desc).first
          if latest.number != attestation.attempt.number
            if latest.attestation
              attestation.update!(invalidated_at: now, invalidation_reason: "superseded")
              return false
            end
            if latest.state == "running"
              return false if latest.started_at > now - STALE_ATTEMPT_AFTER
              latest.update!(state: "blocked", decision: "blocked", failure_class: "infrastructure",
                failure_code: "verification_interrupted",
                message: I18n.t("services.runtime_images.verifications.reevaluator.abandoned"), finished_at: now)
            end
          end
          image.update!(verification_state: "unverified")
          true
        end
      end
    end
  end
end
