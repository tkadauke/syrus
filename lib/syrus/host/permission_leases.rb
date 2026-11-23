require "forwardable"

module Syrus
  module Host
    # Queries over permission leases.
    module PermissionLeases
      extend SingleForwardable

      def_delegators "::PermissionLease", :where
    end
  end
end
