module Syrus
  module Plugin
    # Allows an optional plugin to own the admission and execution context for
    # a chat turn while core retains the generic invocation loop.
    module ChatTurnLifecycle
      def self.included(base) = base.extend(self)
    end
  end
end
