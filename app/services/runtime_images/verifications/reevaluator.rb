module RuntimeImages
  module Verifications
    class Reevaluator
      UNRESOLVED_BUILD_RESULT = Object.new.freeze

      def initialize(orchestrator: Orchestrator.new, build_runner: Builds::Runner.new)
        @orchestrator = orchestrator
        @build_runner = build_runner
      end

      def due?(attestation, policy:, database_version:, now: Time.current, build_result: UNRESOLVED_BUILD_RESULT)
        return true if attestation.expires_at <= now
        return true if database_version.present? && attestation.vulnerability_database_version != database_version

        attestation.policy_digest != CanonicalJson.digest(effective_policy(attestation, policy, build_result))
      end

      def call(attestation, policy: Policy.current, database_version: nil, now: Time.current, build_result: UNRESOLVED_BUILD_RESULT)
        return attestation unless mark_reevaluation_pending(attestation)

        result = resolve_build_result(attestation, build_result)
        return @orchestrator.verify(attestation.runtime_image, policy: policy, now: now) unless result

        evidence = result.request.evidences.max_by { |candidate| [ candidate.created_at, candidate.id ] }
        raise ProviderError, "build evidence is unavailable for re-evaluation" unless evidence

        @build_runner.verify_candidate(result.request, attestation.runtime_image, evidence, policy: policy)
      end

      private

      # Eligibility fails closed as soon as re-evaluation starts, but the old
      # attestation remains a scheduling candidate until a replacement attempt
      # supersedes it. An infrastructure failure before verification can then
      # be retried by the next recurring pass instead of stranding the image.
      def mark_reevaluation_pending(attestation)
        image = attestation.runtime_image
        image.with_lock do
          attestation.reload
          return false if attestation.invalidated_at?
          return false unless image.runtime_image_verification_attempts.maximum(:number) == attestation.attempt.number

          image.update!(verification_state: "unverified")
          true
        end
      end

      def effective_policy(attestation, policy, build_result)
        result = resolve_build_result(attestation, build_result)
        result ? @build_runner.verification_policy(result.request, base_policy: policy) : policy
      end

      def resolve_build_result(attestation, provided)
        return provided unless provided.equal?(UNRESOLVED_BUILD_RESULT)

        RuntimeImageBuildResult.includes(request: :evidences).find_by(runtime_image: attestation.runtime_image)
      end
    end
  end
end
