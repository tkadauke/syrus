module Syrus
  module Plugin
    # Interface for plugins that register artifact renderers.
    # Extend this module in a class and implement artifact_type and renderer_type.
    # Register with: PluginRegistry.register(..., provides: { artifact_renderer: MyRenderer })
    module ArtifactRenderer
      def artifact_type
        raise NotImplementedError, "#{name}.artifact_type must be implemented"
      end

      def renderer_type
        raise NotImplementedError, "#{name}.renderer_type must be implemented"
      end
    end
  end
end
