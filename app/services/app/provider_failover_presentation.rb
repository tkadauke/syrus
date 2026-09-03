module App
  class ProviderFailoverPresentation
    def self.for(workflow)
      new(workflow).payload
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def payload
      decision = workflow&.artifact("provider_failover_decision").to_h
      original = decision["original_provider"].presence
      selected = decision["selected_provider"].presence
      return nil if original.blank? || selected.blank? || original == selected

      {
        original_provider: original,
        original_provider_label: App::Presentation.agent_provider_label(original),
        selected_provider: selected,
        selected_provider_label: App::Presentation.agent_provider_label(selected),
        reason: decision["reason"].presence,
        availability_state: decision["availability_state"].presence,
        candidate_availability_state: decision["candidate_availability_state"].presence,
        evidence_observed_at: decision["evidence_observed_at"].presence,
        candidate_evidence_observed_at: decision["candidate_evidence_observed_at"].presence,
        decided_at: decision["decided_at"].presence,
        automatic: decision["automatic_failover"] != false,
        manual_override: decision["manual_override"] == true,
        message: message_for(original, selected)
      }.compact
    end

    private

    attr_reader :workflow

    def message_for(original, selected)
      "#{App::Presentation.agent_provider_label(original)} unavailable; running this workflow with #{App::Presentation.agent_provider_label(selected)}"
    end
  end
end
