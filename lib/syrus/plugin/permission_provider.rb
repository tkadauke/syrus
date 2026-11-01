module Syrus
  module Plugin
    # Declarative permission contract for plugin-owned capabilities and scopes.
    # Register the provider through the +:permission_provider+ extension point.
    module PermissionProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def register_resource_scope(type, **options)
          type = type.to_sym
          raise ArgumentError, "resource scope #{type.inspect} is already registered" if registered_permission_resource_scopes.key?(type)

          schema = Permissions::ResourceScopeSchema.new(type: type, **options)
          registered_permission_resource_scopes[type] = schema
        end

        def register_capability(**attributes)
          attributes = attributes.dup
          scope = attributes.fetch(:resource_scope)
          attributes[:resource_scope] = registered_permission_resource_scopes.fetch(scope.to_sym) if scope.is_a?(String) || scope.is_a?(Symbol)
          descriptor = Permissions::CapabilityDescriptor.new(**attributes)
          if registered_permission_capability_descriptors.any? { |registered| registered.operation == descriptor.operation }
            raise ArgumentError, "operation #{descriptor.operation.inspect} is already registered"
          end

          registered_permission_capability_descriptors << descriptor
          descriptor
        end

        def migrate_permission_scope(from_operation:, to_operation:, with:)
          migration = Permissions::CapabilityScopeMigration.new(
            from_operation: from_operation,
            to_operation: to_operation,
            transform: with
          )
          if registered_permission_scope_migrations.any? { |registered| registered.from_operation == migration.from_operation }
            raise ArgumentError, "scope migration from #{migration.from_operation.inspect} is already registered"
          end

          registered_permission_scope_migrations << migration
          migration
        end

        def retire_permission_identifier(identifier)
          identifier = identifier.to_s
          unless identifier.match?(/\A[a-z][a-z0-9_.-]*(?:\/[a-z][a-z0-9_.-]*)?@v[1-9]\d*\z/)
            raise ArgumentError, "retired permission identifier must be versioned"
          end
          raise ArgumentError, "permission identifier #{identifier.inspect} is already retired" if registered_retired_permission_identifiers.include?(identifier)

          registered_retired_permission_identifiers << identifier.freeze
          identifier
        end

        def validate_permission_upgrade!(previous_descriptors:, retired_identifiers: retired_permission_identifiers)
          Permissions::CapabilityUpgradeValidator.new(
            previous: previous_descriptors,
            current: permission_capability_descriptors,
            scope_migrations: permission_scope_migrations,
            retired_identifiers: retired_identifiers
          ).validate!
        end

        def capability_descriptor(operation)
          registered_permission_capability_descriptors.find { |descriptor| descriptor.operation == operation.to_s } ||
            raise(KeyError, "unknown permission operation: #{operation}")
        end

        def permission_capability_descriptors
          registered_permission_capability_descriptors.dup.freeze
        end

        def permission_resource_scopes
          registered_permission_resource_scopes.dup.freeze
        end

        def permission_scope_migrations
          registered_permission_scope_migrations.dup.freeze
        end

        def retired_permission_identifiers
          registered_retired_permission_identifiers.dup.freeze
        end

        private

        def registered_permission_capability_descriptors
          @permission_capability_descriptors ||= []
        end

        def registered_permission_resource_scopes
          @permission_resource_scopes ||= {}
        end

        def registered_permission_scope_migrations
          @permission_scope_migrations ||= []
        end

        def registered_retired_permission_identifiers
          @retired_permission_identifiers ||= []
        end
      end
    end
  end
end
