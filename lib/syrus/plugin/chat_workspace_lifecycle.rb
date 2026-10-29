module Syrus
  module Plugin
    # Lets an optional plugin provide a durable checkout around a chat turn.
    # The first applicable provider prepares the checkout before invocation and
    # finalizes it before the turn is released to queued messages.
    module ChatWorkspaceLifecycle
      def self.included(base) = base.extend(self)
    end
  end
end
