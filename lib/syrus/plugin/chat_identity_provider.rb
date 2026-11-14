module Syrus
  module Plugin
    # Owns a plugin-defined participant or agent identity on generic chat
    # surfaces. Identity providers return JSON-ready hashes; the host validates
    # and freezes those envelopes before exposing them to callers.
    #
    # Providers may implement only the surfaces they own:
    #
    #   .chat_identities(chat_session:, user:) => [identity]
    #   .chat_turn_identity(chat_session:, message:) => identity or nil
    #   .chat_turn_trigger(chat_session:, message:, mentions:) => decision or nil
    #   .chat_search_ownership(user:) => search ownership or nil
    #   .chat_group_ownership(user:) => group ownership or nil
    #   .chat_message_presentations(messages:) => { message_id => presentation }
    #   .chat_status_contributions(chat_sessions:, user:) => { chat_id => status }
    #
    # An identity has stable `provider`, `kind`, and `id` keys plus a display
    # snapshot. Snapshots are deliberately self-contained so historical chat
    # records remain understandable while the provider is disabled or absent.
    # A trigger decision is `{ trigger: true|false, reason: String }`; nil means
    # the provider does not own that turn and the host policy remains in force.
    module ChatIdentityProvider
      def self.included(base) = base.extend(self)

      def chat_identities(chat_session:, user:) = []
      def chat_turn_identity(chat_session:, message:) = nil
      def chat_turn_trigger(chat_session:, message:, mentions:) = nil
      def chat_search_ownership(user:) = nil
      def chat_group_ownership(user:) = nil
      def chat_message_presentations(messages:) = {}
      def chat_status_contributions(chat_sessions:, user:) = {}
    end
  end
end
