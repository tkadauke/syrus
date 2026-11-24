require "forwardable"

module Syrus
  module Host
    # Queries and transactions over durable permission rules; evaluation and
    # authorization decisions stay in the core permission engine.
    module PermissionRules
      extend SingleForwardable

      def_delegators "::PermissionRule", :where, :active, :transaction, :create!
    end
  end
end
