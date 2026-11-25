module Syrus
  module Plugin
    # Allows an optional plugin to own the admission and execution context for
    # a chat turn while core retains the generic invocation loop.
    # Implementations provide .applies_to?, #admission, #context,
    # #isolated_workspace?, and #synchronize.
    module ChatTurnLifecycle
      def self.included(base) = base.extend(self)
    end
  end
end
