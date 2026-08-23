module WorkDefinitions
  class RegistryValidator
    Error = Data.define(:code, :message) do
      def initialize(code:, message:)
        super(code: code.to_s, message: message.to_s)
      end
    end

    def self.call = new.call

    def call
      errors = []
      errors.concat(validate_trigger_entries)
      errors.concat(validate_definitions)
      errors.concat(validate_definition_constants)
      errors
    end

    private

    def validate_trigger_entries
      Workflow::TriggerKind::ENTRIES.flat_map do |entry|
        errors = []
        errors << error(:invalid_runtime_role, "Workflow trigger #{entry.kind.inspect} has invalid runtime_role #{entry.runtime_role.inspect}") unless Workflow::TriggerKind::RUNTIME_ROLES.include?(entry.runtime_role)
        definition_class = WorkDefinitions.registry[entry.kind]
        if definition_class.nil?
          errors << error(:missing_definition, "Workflow trigger #{entry.kind.inspect} has no WorkDefinitions entry")
        else
          definition = definition_class.new
          errors << error(:runtime_role_mismatch, "Workflow trigger #{entry.kind.inspect} role #{entry.runtime_role.inspect} does not match WorkDefinition role #{definition.runtime_role.inspect}") unless definition.runtime_role == entry.runtime_role
          errors << error(:trigger_kind_mismatch, "WorkDefinition #{definition.kind.inspect} points to #{definition.workflow_trigger_kind.inspect}, expected #{entry.kind.inspect}") unless definition.workflow_trigger_kind == entry.kind
        end
        errors
      end
    end

    def validate_definitions
      WorkDefinitions.registry.values.flat_map do |definition_class|
        definition = definition_class.new
        errors = []
        errors << error(:missing_kind, "#{definition_class.name} does not declare kind") if definition.kind.blank?
        errors << error(:missing_workflow_trigger_kind, "#{definition_class.name} does not declare workflow_trigger_kind") if definition.workflow_trigger_kind.blank?
        errors << error(:unknown_workflow_trigger_kind, "WorkDefinition #{definition.kind.inspect} points to unknown workflow trigger #{definition.workflow_trigger_kind.inspect}") unless trigger_kind_exists?(definition.workflow_trigger_kind)
        errors << error(:missing_scope, "WorkDefinition #{definition.kind.inspect} does not declare scope") if definition.scope.blank?
        errors << error(:invalid_runtime_role, "WorkDefinition #{definition.kind.inspect} has invalid runtime_role #{definition.runtime_role.inspect}") unless Workflow::TriggerKind::RUNTIME_ROLES.include?(definition.runtime_role)
        errors << error(:invalid_intent_gates, "WorkDefinition #{definition.kind.inspect} intent_gates must be an Array") unless definition.intent_gates.is_a?(Array)
        errors << error(:invalid_unit_gates, "WorkDefinition #{definition.kind.inspect} unit_gates must be an Array") unless definition.unit_gates.is_a?(Array)
        errors << error(:missing_preemption_policy, "WorkDefinition #{definition.kind.inspect} does not expose a preemption policy") if definition.preemption_policy.nil?
        errors << error(:missing_retry_policy, "WorkDefinition #{definition.kind.inspect} does not expose a retry policy") if definition.retry_policy.nil?
        errors.concat(validate_preemption_policy(definition))
        errors.concat(validate_child_definition(definition))
        errors.concat(validate_landing_policy(definition))
        errors.concat(validate_template(definition))
        errors
      end
    end

    def validate_preemption_policy(definition)
      policy = definition.preemption_policy
      return [] unless policy

      errors = []
      errors << error(:invalid_preemption_mode, "WorkDefinition #{definition.kind.inspect} has invalid preemption mode #{policy.mode.inspect}") unless policy.mode.in?(%i[none cancel checkpoint rebuild])
      errors << error(:invalid_preemption_resume_strategy, "WorkDefinition #{definition.kind.inspect} has invalid preemption resume strategy #{policy.resume_strategy.inspect}") unless policy.resume_strategy.in?(%i[none new_attempt checkpoint_resume rebuild_unit])
      errors
    end

    def validate_child_definition(definition)
      return [] unless definition.child?

      errors = []
      if definition.parent_kind.blank?
        errors << error(:missing_parent_kind, "Child WorkDefinition #{definition.kind.inspect} must declare parent_kind")
      elsif WorkDefinitions.registry[definition.parent_kind].nil?
        errors << error(:unknown_parent_kind, "Child WorkDefinition #{definition.kind.inspect} declares unknown parent_kind #{definition.parent_kind.inspect}")
      end
      errors
    end

    def validate_landing_policy(definition)
      errors = []
      landing_path_kinds = WorkUnits::PathOwnership::LANDING_PATHS

      if definition.landing_lock? && !landing_path_kinds.include?(definition.kind)
        errors << error(:missing_landing_path, "Landing WorkDefinition #{definition.kind.inspect} has no WorkUnits::PathOwnership landing path")
      end

      if definition.landing_validation_prefetch_source? && WorkDefinitions.landing_validation_child_kind_for(definition.kind).blank?
        errors << error(:missing_landing_validation_child, "Landing prefetch WorkDefinition #{definition.kind.inspect} has no validation child definition")
      end

      if definition.landing_validation_child?
        parent = WorkDefinitions.registry[definition.parent_kind]&.new
        unless parent&.landing_validation_prefetch_source?
          errors << error(:invalid_landing_validation_parent, "Landing validation child #{definition.kind.inspect} must point to a landing prefetch source parent")
        end
      end

      if WorkDefinitions::Base::LANDING_LOCK_KINDS.include?(definition.kind) && !definition.landing_lock?
        errors << error(:stale_landing_lock_kind, "LANDING_LOCK_KINDS includes #{definition.kind.inspect} but the definition does not report landing_lock?")
      end

      errors
    end

    def validate_definition_constants
      WorkDefinitions::Base::LANDING_LOCK_KINDS.filter_map do |kind|
        next if WorkDefinitions.registry.key?(kind)

        error(:unknown_landing_lock_kind, "LANDING_LOCK_KINDS includes unknown WorkDefinition #{kind.inspect}")
      end
    end

    def validate_template(definition)
      template = definition.workflow_template
      errors = []
      errors << error(:invalid_template, "WorkDefinition #{definition.kind.inspect} template #{template.name} does not implement .instantiate") unless template.respond_to?(:instantiate)
      errors
    rescue NameError, ArgumentError => e
      [ error(:invalid_template, "WorkDefinition #{definition.kind.inspect} has invalid template: #{e.class}: #{e.message}") ]
    end

    def trigger_kind_exists?(kind)
      Workflow::TriggerKind.fetch(kind)
      true
    rescue ArgumentError
      false
    end

    def error(code, message)
      Error.new(code: code, message: message)
    end
  end
end
