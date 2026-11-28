module RuntimeImages
  module Verifications
    # Adapter for an existing verification callable. It keeps orchestration
    # polymorphic while older probes migrate to structured verifier results.
    class CallableVerifier
      def initialize(callable, evidence_kind:)
        @callable = callable
        @evidence_kind = evidence_kind
      end

      def call(image:, **)
        @callable.call(image)
        Result.pass(evidence_references: [ { "kind" => @evidence_kind, "digest" => image.digest } ])
      rescue ConformanceProbe::NonConformant, RuntimeAbi::Incompatible => e
        Result.fail(failure_class: :policy, code: :conformance_failed, message: e.message)
      end
    end
  end
end
