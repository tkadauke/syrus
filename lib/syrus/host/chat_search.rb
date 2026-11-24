require "forwardable"

module Syrus
  module Host
    # Full-text matching over chat messages. Index storage and ranking are not
    # promised.
    module ChatSearch
      extend SingleForwardable

      def_delegators "::ChatMessageSearchIndex", :matching_chat_session_page, :top_matches_by_chat_session
    end
  end
end
