module Syrus
  module Plugin
    # Interface for grader augmentors registered with PluginRegistry under
    # :grader_augmentor. Augmentors are called after a grader command fails and
    # can append additional diagnostic lines to the run log.
    #
    # Implementations must define:
    #
    #   augment_grader_failure(name:, command:, workspace_path:) -> Array<String> | nil
    #     Called after a grader command exits with a non-zero status. Return an
    #     array of log lines to append to the grade_log, or nil/[] to add nothing.
    #     Each element should end with "\n". The method must not raise — any
    #     errors should be handled internally (e.g. missing files, parse errors).
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin",
    #     version: "1.0.0",
    #     provides: { grader_augmentor: MyAugmentor }
    #   )
    module GraderAugmentor
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def augment_grader_failure(name:, command:, workspace_path:)
          raise NotImplementedError, "#{self}#augment_grader_failure is not implemented"
        end
      end

      def augment_grader_failure(name:, command:, workspace_path:)
        raise NotImplementedError, "#{self.class}#augment_grader_failure is not implemented"
      end
    end
  end
end
