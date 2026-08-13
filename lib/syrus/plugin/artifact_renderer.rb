module Syrus
  module Plugin
    # Interface for artifact renderer plugins. Include this module in a class and
    # implement .artifact_type and .renderer_type to declare how an artifact type
    # should be displayed in the Syrus job detail UI.
    #
    #   class SchemaErdRenderer
    #     include Syrus::Plugin::ArtifactRenderer
    #
    #     def self.artifact_type = "rails_schema_erd"
    #     def self.renderer_type = :erd_diagram
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "syrus_rails", version: "1.0.0",
    #     provides: { artifact_renderer: [SchemaErdRenderer, MigrationDiffRenderer] }
    #   )
    #
    # A plugin may register multiple renderer classes (one per artifact type) by
    # passing an array to the :artifact_renderer key.
    module ArtifactRenderer
      VALID_RENDERER_TYPES = %i[erd_diagram migration_diff data_table before_after_diff image_diff].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # @return [String] the artifact type identifier this renderer handles
        #   (e.g. "rails_schema_erd", "rails_migration_diff")
        def artifact_type
          raise NotImplementedError, "#{name} must implement .artifact_type"
        end

        # @return [Symbol] the core renderer type, one of
        #   :erd_diagram, :migration_diff, :data_table, :before_after_diff, :image_diff
        def renderer_type
          raise NotImplementedError, "#{name} must implement .renderer_type"
        end

        # Optional JSON Schema documenting the payload structure for this artifact
        # type. Purely for documentation — not validated at runtime.
        #
        # @return [Hash, nil]
        def payload_schema
          nil
        end
      end
    end
  end
end
