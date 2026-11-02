module Syrus
  module Plugin
    # Narrows repository relations on general-purpose discovery surfaces.
    # Direct repository access and authorization remain separate concerns.
    module RepositoryFilter
      def self.included(base) = base.extend(self)

      def apply(scope:, user:) = raise(NotImplementedError, "#{self} must define .apply")
    end
  end
end
