require "forwardable"

module Syrus
  module Host
    # Run queries. Dispatch, lifecycle transitions, and persistence are not
    # promised.
    module Runs
      extend SingleForwardable

      def_delegators "::Run", :where, :joins, :find
    end
  end
end
