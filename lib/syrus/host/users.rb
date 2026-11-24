require "forwardable"

module Syrus
  module Host
    # User lookups and counts. Credentials, preferences, and persistence are
    # not promised.
    module Users
      extend SingleForwardable

      def_delegators "::User", :where, :find, :find_by, :order, :limit, :count, :chat_providers

      def self.user?(object) = object.is_a?(::User)
    end
  end
end
