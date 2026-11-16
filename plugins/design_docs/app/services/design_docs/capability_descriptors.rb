module DesignDocs
  module CapabilityDescriptors
    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES).uniq.freeze
    OPERATIONS = {
      "list_design_docs" => [ "read", "list", %i[confidential_read], :low, :allow ],
      "read_design_doc" => [ "read", "read", %i[confidential_read], :low, :allow ],
      "list_design_doc_sections" => [ "read", "list_sections", %i[confidential_read], :low, :allow ],
      "propose_design_doc" => [ "collaboration", "propose", %i[internal_write communication], :medium, :ask ],
      "comment_on_design_doc" => [ "collaboration", "comment", %i[internal_write communication], :medium, :ask ],
      "suggest_design_doc_change" => [ "collaboration", "suggest_change", %i[internal_write communication], :medium, :ask ],
      "archive_design_docs" => [ "lifecycle", "archive", %i[internal_write destructive], :high, :ask ],
      "delete_design_doc" => [ "lifecycle", "delete", %i[internal_write destructive], :high, :ask ]
    }.freeze

    def self.for(tool_name)
      family, name, effects, risk, default = OPERATIONS.fetch(tool_name)
      mutation = effects.include?(:internal_write)
      Permissions::PluginToolDescriptor.build(
        capability: "design_docs.#{family}@v1", operation: "design_docs/#{name}@v1",
        effects:, risk:, roles: ROLES, default:, maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        scope_keys: %w[doc_ref design_doc_id repository_id]
      )
    end
  end
end
