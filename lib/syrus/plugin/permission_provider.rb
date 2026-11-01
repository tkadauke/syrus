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

        private

        def registered_permission_capability_descriptors
          @permission_capability_descriptors ||= []
        end

        def registered_permission_resource_scopes
          @permission_resource_scopes ||= {}
        end
      end
    end
  end
end
