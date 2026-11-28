module RuntimeImages
  module Verifications
    class Reevaluator
      def initialize(orchestrator: Orchestrator.new, build_runner: Builds::Runner.new)
        @orchestrator = orchestrator
        @build_runner = build_runner
      end

      def call(attestation, policy: Policy.current, now: Time.current)
        attestation.update!(invalidated_at: now, invalidation_reason: reason(attestation, policy)) if attestation.invalidated_at.nil?
        result = RuntimeImageBuildResult.includes(request: :evidences).find_by(runtime_image: attestation.runtime_image)
        return @orchestrator.verify(attestation.runtime_image, policy: policy, now: now) unless result

        evidence = result.request.evidences.last
        raise ProviderError, "build evidence is unavailable for re-evaluation" unless evidence

        @build_runner.verify_candidate(result.request, attestation.runtime_image, evidence)
      end

      private

      def reason(attestation, policy)
        updated_policy = attestation.attempt.policy_snapshot.deep_merge(policy.except("checks"))
        digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(updated_policy)))}"
        attestation.policy_digest == digest ? "expired" : "policy_changed"
      end

      def canonical(value)
        return value.stringify_keys.sort.to_h { |key, item| [ key, canonical(item) ] } if value.is_a?(Hash)
        return value.map { |item| canonical(item) } if value.is_a?(Array)
        value
      end
    end
  end
end
