module Syrus
  module Plugin
    # Contributes one group to the main chat list. Providers perform one
    # batched lookup and return:
    #
    #   .chat_list_group(user:) => {
    #     key: "coworkers",
    #     label: "Coworkers",
    #     chat_session_ids: [ 1, 2, 3 ]
    #   }
    #
    # Core intersects those ids with +user.accessible_chat_sessions+ before
    # rendering them. Keys must be stable and unique across providers because
    # they are used by the chat-list pagination endpoint.
    module ChatListGroup
      def self.included(base) = base.extend(self)

      def chat_list_group(user:) = raise(NotImplementedError, "#{self} must define .chat_list_group")
    end
  end
end
