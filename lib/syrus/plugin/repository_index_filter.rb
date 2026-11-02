module Syrus
  module Plugin
    # Narrows the relation displayed on the general Repositories index. Direct
    # repository access and authorization remain separate concerns.
    module RepositoryIndexFilter
      def self.included(base) = base.extend(self)

      def apply(scope:, user:) = raise(NotImplementedError, "#{self} must define .apply")
    end
  end
end
