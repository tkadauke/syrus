module DesignDocs
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES).uniq.freeze
    CAPABILITY = "design_docs.documents@v1"
    EFFECTS = {
      "list_design_docs" => %i[confidential_read], "read_design_doc" => %i[confidential_read],
      "list_design_doc_sections" => %i[confidential_read], "propose_design_doc" => %i[internal_write],
      "comment_on_design_doc" => %i[internal_write communication], "suggest_design_doc_change" => %i[internal_write],
      "archive_design_docs" => %i[internal_write], "delete_design_doc" => %i[internal_write destructive]
    }.freeze
    OPERATIONS = EFFECTS.keys.index_with { |name| "design_docs.documents/#{name}@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 200 ? "[REDACTED CONTENT]" : value }
    end

    # Reading design docs is research. Drafting, suggesting and archiving
    # change documents other people read, so they stay deniable.
    ESSENTIAL = %w[list_design_docs read_design_doc list_design_doc_sections].freeze
    DENIABLE_REASONS = %w[propose_design_doc suggest_design_doc_change archive_design_docs].index_with { :shared_state }.freeze

    EFFECTS.each do |name, effects|
      operation = OPERATIONS.fetch(name)
      mutation = effects.include?(:internal_write)
      risk = effects.include?(:destructive) ? :high : (mutation ? :medium : :low)
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        effects:, risk:, requestable_roles: ROLES,
        essential: ESSENTIAL.include?(name), deniable_reason: DENIABLE_REASONS[name],
        defaults: ROLES.index_with { mutation ? :ask : :allow }, maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
