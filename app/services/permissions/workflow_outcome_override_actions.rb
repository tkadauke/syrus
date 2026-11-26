module Permissions
  # Versioned authority contracts for inspecting, requesting, and executing an
  # exact-evidence workflow outcome override. These are ordinary permission
  # capabilities: administrator status is neither a grant nor a requirement.
  class WorkflowOutcomeOverrideActions
    OBSERVATION = "syrus.workflow_outcome_override_observation@v1".freeze
    CAPABILITY = "syrus.workflow_outcome_overrides@v1".freeze
    EXECUTE_OPERATION = "syrus.workflow_outcome_overrides/execute@v1".freeze
    OPERATIONS = {
      "inspect_workflow_outcome_overrides" => [ OBSERVATION, "inspect", %i[local_read], :low, :allow ],
      "request_workflow_outcome_override" => [ CAPABILITY, "request", %i[internal_write operational], :high, :ask ],
      "execute_workflow_outcome_override" => [ CAPABILITY, "execute", %i[internal_write operational], :high, :ask ]
    }.freeze

    class << self
      def authority_descriptors
        roles = AgentRole::CHAT_ROLES + [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]
        %w[request_workflow_outcome_override execute_workflow_outcome_override].map { |name| descriptor_for(name, required_roles: roles) }
      end

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        capability, name, effects, risk, default = OPERATIONS.fetch(tool_name.to_s)
        operation = "#{capability.delete_suffix('@v1')}/#{name}@v1"
        roles = Array(required_roles)
        CapabilityDescriptor.new(
          capability:, operation:,
          presentation: CapabilityPresentation.for(capability:, operation:),
          effects:, risk:, requestable_roles: roles,
          defaults: roles.index_with { default },
          maximum_autonomy: name == "execute" ? :invocation : :permanent,
          authority_durations: name == "execute" ? %i[invocation] : CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:normalize_arguments)
        )
      end

      def normalize_arguments(arguments)
        arguments.to_h.transform_keys(&:to_s).except("diagnosis", "remediation_attempted", "reason")
          .reject { |_key, value| value.nil? }.sort.to_h
      end
    end
  end
end
