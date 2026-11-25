module WorkflowOutcomeOverrides
  class Recorder
    class InvalidRequest < ArgumentError; end

    def self.call(...) = new(...).call

    def initialize(job:, fingerprint_digest:, actor:, channel:, reason:, permission_decision:)
      @job, @fingerprint_digest, @actor, @channel = job, fingerprint_digest, actor, channel
      @reason, @permission_decision = reason.to_s.strip, permission_decision
    end

    def call
      raise InvalidRequest, "reason is required" if reason.blank?
      candidate = CandidateResolver.new(job).find!(fingerprint_digest)
      existing = WorkflowOutcomeOverride.find_by(fingerprint_digest:, invalidation_cause: nil)
      return existing if existing

      WorkflowOutcomeOverride.record!(
        **candidate.attributes, gate_failure: candidate.gate_failure,
        actor:, channel:, reason:, permission_decision:
      )
    end

    private

    attr_reader :job, :fingerprint_digest, :actor, :channel, :reason, :permission_decision
  end
end
