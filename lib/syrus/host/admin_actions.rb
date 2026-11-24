require "forwardable"

module Syrus
  module Host
    # Writes and reads audit entries. Storage and retention are not promised.
    module AdminActions
      extend SingleForwardable

      def_delegators "::AdminAction", :log!, :where
    end
  end
end
