require "forwardable"

module Syrus
  module Host
    # Read queries over chat messages, plus the one extension hook plugins use
    # to observe message creation. Persistence and callbacks are not promised.
    module ChatMessages
      extend SingleForwardable

      def_delegators "::ChatMessage", :find, :find_by, :where, :active, :none

      def self.install_after_commit_on_create(concern, callback)
        ::ChatMessage.include(concern) unless ::ChatMessage < concern
        ::ChatMessage.set_callback(:commit, :after, callback, on: :create)
      end

      def self.remove_after_commit_on_create(callback)
        ::ChatMessage.skip_callback(:commit, :after, callback, on: :create)
      end
    end
  end
end
