module WorkflowOutcomeOverrides
  # Dispatches through the registered gate contract so future gate kinds own
  # their continuation behavior alongside their failure contract.
  class Resumer
    class ResumeFailed < StandardError; end

    def self.call(override:)
      new(override:).call
    rescue ResumeFailed
      override.invalidate!("resume_failed") unless override.consumed? || override.invalidated?
      raise
    end

    def initialize(override:)
      @override = override
    end

    def call
      GateRegistry.default.fetch(override.gate_kind).resume(override)
    end

    private

    attr_reader :override
  end
end
