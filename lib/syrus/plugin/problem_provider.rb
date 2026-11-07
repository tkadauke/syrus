module Syrus
  module Plugin
    # Contributes stable problem kinds under a plugin-owned namespace. The
    # namespace remains meaningful in historical diagnostics without loading
    # plugin code.
    module ProblemProvider
      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def problem_namespace = raise NotImplementedError
        def problem_kinds = []
      end
    end
  end
end
