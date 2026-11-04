require_dependency "permissions/tool_set_bundle"

module Permissions
  module ToolSetBundles
    DEFINITIONS = [
      ToolSetBundle.new(key: "workspace@v1", label: "Workspace", description: "Read, edit, build, and test in an isolated workspace."),
      ToolSetBundle.new(key: "knowledge@v1", label: "Knowledge", description: "Read visible Syrus and external information."),
      ToolSetBundle.new(key: "collaboration@v1", label: "Collaboration", description: "Create drafts, organize work, and communicate."),
      ToolSetBundle.new(key: "operations@v1", label: "Operations", description: "Use credentials, change external state, and operate persistent work."),
      ToolSetBundle.new(key: "administration@v1", label: "Administration", description: "Perform privileged, destructive, financial, or host-level actions.")
    ].index_by(&:key).freeze

    ADMINISTRATION_EFFECTS = %i[financial privilege_change destructive irreversible operator_host_access].freeze
    OPERATIONS_EFFECTS = %i[credential_use external_write operational persistent_autonomy].freeze
    COLLABORATION_EFFECTS = %i[internal_write communication].freeze
    KNOWLEDGE_EFFECTS = %i[network_read confidential_read].freeze
    WORKSPACE_EFFECTS = %i[local_read isolated_workspace_write isolated_execution].freeze

    class << self
      def all = DEFINITIONS.values
      def fetch(key) = DEFINITIONS.fetch(key.to_s)

      # Classification is effect-based so plugin capabilities join the same
      # human-sized bundles as core capabilities without a core plugin-name list.
      def classify(effects)
        effects = Array(effects).map(&:to_sym)
        return "administration@v1" if (effects & ADMINISTRATION_EFFECTS).any?
        return "operations@v1" if (effects & OPERATIONS_EFFECTS).any?
        return "collaboration@v1" if (effects & COLLABORATION_EFFECTS).any?
        return "knowledge@v1" if (effects & KNOWLEDGE_EFFECTS).any?
        return "workspace@v1" if effects.present? && (effects - WORKSPACE_EFFECTS).empty?

        unknown = effects - CapabilityDescriptor::EFFECTS
        raise ArgumentError, "unknown effects cannot be bundled: #{unknown.join(', ')}" if unknown.any?

        raise ArgumentError, "effects do not map to a tool-set bundle: #{effects.join(', ')}"
      end
    end
  end
end
