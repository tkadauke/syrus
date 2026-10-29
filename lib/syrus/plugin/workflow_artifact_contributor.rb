module Syrus
  module Plugin
    # Adds immutable, repository-derived input to a Workflow before its
    # workspace is cloned. Providers return a Hash suitable for merging into
    # Workflow#artifacts and must read repository files through
    # RepositoryContent.
    module WorkflowArtifactContributor
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def for_job(_job)
          {}
        end
      end
    end
  end
end
