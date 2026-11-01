module Permissions
  class CapabilityUpgradeValidator
    AUTONOMY_RANK = CapabilityDescriptor::AUTONOMY_CEILINGS.each_with_index.to_h.freeze
    POLICY_RANK = CapabilityDescriptor::POLICIES.each_with_index.to_h.freeze
    RISK_RANK = CapabilityDescriptor::RISKS.each_with_index.to_h.freeze

    Finding = Data.define(:code, :message)

    class ValidationError < StandardError
      attr_reader :findings

      def initialize(findings)
        @findings = findings
        super("Capability upgrade validation failed:\n- #{findings.map(&:message).join("\n- ")}")
      end
    end

    def initialize(previous:, current:, scope_migrations: [], retired_identifiers: [])
      @previous = Array(previous)
      @current = Array(current)
      @scope_migrations = Array(scope_migrations)
      @retired_identifiers = Array(retired_identifiers).map(&:to_s)
    end

    def validate!
      raise ValidationError, findings if findings.any?

      true
    end

    def findings
      retired_identifier_findings + migration_contract_findings + unaccounted_removal_findings +
        capability_family_change_findings + missing_migration_findings + semantic_widening_findings
    end

    private

    attr_reader :previous, :current, :scope_migrations, :retired_identifiers

    def retired_identifier_findings
      claims = current.flat_map do |descriptor|
        [ descriptor.capability, descriptor.operation, *descriptor.capability_aliases, *descriptor.operation_aliases ]
      end
      (claims & retired_identifiers).map do |identifier|
        Finding.new(:retired_identifier_reused, "retired capability identifier #{identifier.inspect} cannot be reused")
      end
    end

    def unaccounted_removal_findings
      operation_findings = previous.filter_map do |old_descriptor|
        next if successor_for(old_descriptor)
        next if retired_identifiers.include?(old_descriptor.operation)

        Finding.new(
          :unaccounted_identifier_removal,
          "operation #{old_descriptor.operation.inspect} was removed without an alias, scope migration, or retained retirement declaration"
        )
      end
      capability_findings = previous.map(&:capability).uniq.filter_map do |old_capability|
        next if current.any? { |descriptor| descriptor.capability == old_capability || descriptor.capability_aliases.include?(old_capability) }
        next if retired_identifiers.include?(old_capability)

        Finding.new(
          :unaccounted_identifier_removal,
          "capability #{old_capability.inspect} was removed without an alias or retained retirement declaration"
        )
      end
      operation_findings + capability_findings
    end

    def migration_contract_findings
      duplicate_sources = scope_migrations.group_by(&:from_operation).select { |_source, entries| entries.many? }.keys
      findings = duplicate_sources.map do |source|
        Finding.new(:ambiguous_scope_migration, "operation #{source.inspect} has more than one scope migration")
      end
      scope_migrations.each do |migration|
        unless previous.any? { |descriptor| descriptor.operation == migration.from_operation }
          findings << Finding.new(:unknown_scope_migration_source, "scope migration source #{migration.from_operation.inspect} is not present in the previous contract")
        end
        unless current.any? { |descriptor| descriptor.operation == migration.to_operation }
          findings << Finding.new(:unknown_scope_migration_target, "scope migration target #{migration.to_operation.inspect} is not present in the current contract")
        end
      end
      findings
    end

    def capability_family_change_findings
      previous.filter_map do |old_descriptor|
        new_descriptor = successor_for(old_descriptor)
        next unless new_descriptor
        next if new_descriptor.capability == old_descriptor.capability
        next if new_descriptor.capability_aliases.include?(old_descriptor.capability)

        Finding.new(
          :capability_family_changed,
          "operation #{old_descriptor.operation.inspect} moves from capability #{old_descriptor.capability.inspect} " \
            "to #{new_descriptor.capability.inspect} without a capability alias"
        )
      end
    end

    def missing_migration_findings
      previous.filter_map do |old_descriptor|
        new_descriptor = successor_for(old_descriptor)
        next unless new_descriptor
        next if same_scope_contract?(old_descriptor, new_descriptor)
        next if migration_for(old_descriptor, new_descriptor)

        Finding.new(
          :missing_scope_migration,
          "operation #{old_descriptor.operation.inspect} changes resource scope in #{new_descriptor.operation.inspect} without an explicit scope migration"
        )
      end
    end

    def semantic_widening_findings
      previous.filter_map do |old_descriptor|
        new_descriptor = successor_for(old_descriptor)
        next unless new_descriptor

        dimensions = widened_dimensions(old_descriptor, new_descriptor)
        next if dimensions.empty?

        Finding.new(
          :semantic_widening,
          "operation #{old_descriptor.operation.inspect} widens authority as #{new_descriptor.operation.inspect}: #{dimensions.join(', ')}; publish a separate capability instead"
        )
      end
    end

    def successor_for(old_descriptor)
      current.find do |candidate|
        candidate.operation == old_descriptor.operation ||
          candidate.operation_aliases.include?(old_descriptor.operation) ||
          migration_for(old_descriptor, candidate)
      end
    end

    def migration_for(old_descriptor, new_descriptor)
      scope_migrations.find do |migration|
        migration.from_operation == old_descriptor.operation && migration.to_operation == new_descriptor.operation
      end
    end

    def same_scope_contract?(old_descriptor, new_descriptor)
      old_descriptor.resource_scope.to_h == new_descriptor.resource_scope.to_h
    end

    def widened_dimensions(old_descriptor, new_descriptor)
      dimensions = []
      dimensions << "effects" unless (new_descriptor.effects - old_descriptor.effects).empty?
      dimensions << "risk" if RISK_RANK.fetch(new_descriptor.risk) > RISK_RANK.fetch(old_descriptor.risk)
      dimensions << "requestable roles" unless (new_descriptor.requestable_roles - old_descriptor.requestable_roles).empty?
      dimensions << "maximum autonomy" if AUTONOMY_RANK.fetch(new_descriptor.maximum_autonomy) > AUTONOMY_RANK.fetch(old_descriptor.maximum_autonomy)
      dimensions << "authority durations" unless (new_descriptor.authority_durations - old_descriptor.authority_durations).empty?
      dimensions << "maximum duration" if duration_widened?(old_descriptor.maximum_duration, new_descriptor.maximum_duration)
      dimensions << "role defaults" if defaults_widened?(old_descriptor, new_descriptor)
      dimensions
    end

    def duration_widened?(old_duration, new_duration)
      return false if old_duration.nil?
      return true if new_duration.nil?

      new_duration > old_duration
    end

    def defaults_widened?(old_descriptor, new_descriptor)
      (old_descriptor.defaults.keys & new_descriptor.defaults.keys).any? do |role|
        POLICY_RANK.fetch(new_descriptor.defaults.fetch(role)) > POLICY_RANK.fetch(old_descriptor.defaults.fetch(role))
      end
    end
  end
end
