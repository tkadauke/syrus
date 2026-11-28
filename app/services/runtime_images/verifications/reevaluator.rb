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
        reason = invalidation_reason(attestation, policy, database_version, now)
        attestation.update!(invalidated_at: now, invalidation_reason: reason) if attestation.invalidated_at.nil?

        result = resolve_build_result(attestation, build_result)
        return @orchestrator.verify(attestation.runtime_image, policy: policy, now: now) unless result

        evidence = result.request.evidences.order(:created_at, :id).last
        raise ProviderError, "build evidence is unavailable for re-evaluation" unless evidence

        @build_runner.verify_candidate(result.request, attestation.runtime_image, evidence, policy: policy)
      end

      private

      def invalidation_reason(attestation, policy, database_version, now)
        return "expired" if attestation.expires_at <= now
        return "vulnerability_database_changed" if database_version.present? && attestation.vulnerability_database_version != database_version

        "policy_changed"
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
