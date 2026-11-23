require "forwardable"

module Syrus
  module Host
    # Claims, renames, releases, and normalizes the unique handles of owners.
    module Handles
      extend SingleForwardable

      def_delegators "::HandleRegistry", :normalize, :claim!, :rename!, :release!
    end
  end
end
