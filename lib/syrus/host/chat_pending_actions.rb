require "forwardable"

module Syrus
  module Host
    # Read queries over chat pending actions.
    module ChatPendingActions
      extend SingleForwardable

      def_delegators "::ChatPendingAction", :where, :pending
    end
  end
end
