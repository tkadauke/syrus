module RuntimeImages
  # Durable, digest-bound verification of an image already stored by the
  # Runtime Image Service. Verifiers are registered objects with one uniform
  # interface; policy selects and orders them without type switches.
  module Verifications
    Result = Data.define(:outcome, :evidence_references, :failure_class, :code, :message) do
      def self.pass(evidence_references:) = new(outcome: :passed, evidence_references: Array(evidence_references), failure_class: nil, code: nil, message: nil)
      def self.fail(failure_class:, code:, message:, evidence_references: []) = new(outcome: :failed, evidence_references: Array(evidence_references), failure_class: failure_class.to_s, code: code.to_s, message: message.to_s)
      def passed? = outcome.to_sym == :passed
    end

    class Registry
      def initialize
        @verifiers = {}
      end

      def register(key, verifier) = @verifiers[key.to_s] = verifier
      def fetch(key) = @verifiers[key.to_s]
    end
  end
end
