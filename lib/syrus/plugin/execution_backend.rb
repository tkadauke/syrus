module Syrus
  module Plugin
    # Interface for `:execution_backend` extension points. Core owns the
    # Execution::Backend contract and the local fallback; plugins can provide
    # alternate enforcement for a request by answering whether they can run it.
    #
    # Providers implement the same #run(request) contract as Execution::Backend
    # and may decline a request by returning false from .available_for?(request).
    # Core tries enabled providers in registry order and falls back to
    # Execution::Local when none applies.
    module ExecutionBackend
      def self.included(base)
        base.extend(ClassMethods)
      end

      def available_for?(_request)
        true
      end

      module ClassMethods
        def available_for?(_request)
          true
        end
      end
    end
  end
end
