module Syrus
  module Plugin
    # Interface for `:execution_backend` extension points. Core owns the
    # Execution::Backend contract and the local fallback; plugins can provide
    # alternate enforcement for a request by answering whether they can run it.
    #
    # Providers implement the same #run(request) contract as Execution::Backend,
    # identify themselves with .backend_name, and may decline a request by
    # returning false from .available_for?(request). Core only considers the
    # backend selected by the repository and falls back to Execution::Local
    # when it is disabled or unavailable.
    module ExecutionBackend
      def self.included(base)
        base.extend(ClassMethods)
      end

      def available_for?(_request)
        true
      end

      def backend_name
        self.class.backend_name
      end

      module ClassMethods
        def backend_name
          nil
        end

        def available_for?(_request)
          true
        end
      end
    end
  end
end
