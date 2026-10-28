module Syrus
  module Plugin
    # Adds display-only badges to a page of chat search results. Providers must
    # batch their lookup across the supplied sessions and return a hash keyed by
    # chat session id, with an array of JSON-ready badge hashes as each value.
    module ChatResultDecorator
      def self.included(base) = base.extend(self)

      def chat_result_badges(chat_sessions:) = raise(NotImplementedError, "#{self} must define .chat_result_badges")
    end
  end
end
