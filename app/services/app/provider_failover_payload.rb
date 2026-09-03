module App
  class ProviderFailoverPayload
    def self.for_workflow(workflow, configured_provider: nil)
      new(workflow: workflow, configured_provider: configured_provider).payload
    end

    def initialize(workflow:, configured_provider: nil)
      @workflow = workflow
      @configured_provider = configured_provider
    end

    def payload
      return nil unless workflow

      automatic_payload || manual_payload
    end

    private

    attr_reader :workflow, :configured_provider

    def automatic_payload
      decision = workflow.artifacts.to_h["provider_failover_decision"]
      return nil unless decision.is_a?(Hash)

      original = decision["original_provider"].presence
      selected = decision["selected_provider"].presence
      return nil unless original.present? && selected.present? && original != selected

      {
        mode: decision["manual_override"] ? "operator" : "automatic",
        automatic: decision["automatic_failover"] != false && !decision["manual_override"],
        original_provider: original,
        original_provider_label: provider_label(original),
        selected_provider: selected,
        selected_provider_label: provider_label(selected),
        reason: decision["reason"],
        decided_at: decision["decided_at"],
        unavailable: unavailable_payload(decision)
      }.compact
    end

    def manual_payload
      original = configured_provider.presence
      selected = workflow.agent_provider.presence
      return nil unless original.present? && selected.present? && original != selected

      {
        mode: "operator",
        automatic: false,
        original_provider: original,
        original_provider_label: provider_label(original),
        selected_provider: selected,
        selected_provider_label: provider_label(selected),
        reason: "operator_selected_provider",
        decided_at: workflow.created_at&.iso8601
      }
    end

    def unavailable_payload(decision)
      details = decision["unavailable"] || {}
      details = {} unless details.is_a?(Hash)
      provider = details["provider"].presence || decision["original_provider"].presence
      evidence = details["evidence"] || {}
      evidence = {} unless evidence.is_a?(Hash)

      {
        provider: provider,
        label: details["label"].presence || provider_label(provider),
        state: details["state"].presence || decision["availability_state"],
        reason: details["reason"].presence || decision["reason"],
        retry_after: details["retry_after"],
        reset_at: details["reset_at"],
        evidence_source: evidence["source"],
        evidence_status: evidence["status"],
        observed_at: details["observed_at"].presence || evidence["observed_at"].presence || decision["evidence_observed_at"]
      }.compact
    end

    def provider_label(provider)
      return nil if provider.blank?

      App::Presentation.agent_provider_label(provider)
    end
  end
end
