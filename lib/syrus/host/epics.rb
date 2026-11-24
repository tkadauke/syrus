require "forwardable"

module Syrus
  module Host
    # Epic queries and the archived state name. Epic transitions and
    # persistence are not promised.
    module Epics
      extend SingleForwardable

      def_delegators "::Epic", :where

      def self.archived_state = ::Epic::ARCHIVED_STATE
    end
  end
end
