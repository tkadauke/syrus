require "forwardable"

module Syrus
  module Host
    # Claims, renames, releases, and normalizes the unique handles of owners.
    module Handles
      extend SingleForwardable

      FORMAT = ::Handle::FORMAT

      def_delegators "::HandleRegistry", :normalize, :claim!, :rename!, :release!

      def self.taken?(handle) = ::Handle.exists?(handle: handle)
    end
  end
end
