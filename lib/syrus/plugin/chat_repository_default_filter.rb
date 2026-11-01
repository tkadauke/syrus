module Syrus
  module Plugin
    # Narrows the chat relation used to infer the repository for a new chat.
    # Providers must only affect automatic default selection; repository access
    # and explicit repository selection are separate authorization concerns.
    module ChatRepositoryDefaultFilter
      def self.included(base) = base.extend(self)

      def apply(scope:) = raise(NotImplementedError, "#{self} must define .apply")
    end
  end
end
