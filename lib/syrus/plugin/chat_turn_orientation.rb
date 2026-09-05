module Syrus
  module Plugin
    # Marker interface for a plugin that takes over how one chat turn opens,
    # based on the message that triggered it.
    #
    # The sibling of :chat_prompt_injector, and the distinction is the whole
    # reason this exists: an injector adds a section to the *session's* system
    # prompt and is asked once per turn regardless of what arrived, while this
    # is asked about a *specific incoming message* and may replace the user's
    # text as the turn's final section.
    #
    # A walkthrough video is the motivating case. The video is posted as a real
    # chat message, and the turn it triggers should orient the agent to pull
    # the analysis with its own tools rather than paste the analysis in as a
    # fake user message -- so the plugin has to see the message, not the
    # session.
    #
    # Providers expose:
    #
    #   .chat_turn_orientation(chat_session:, message:, user_note:) => String or nil
    #
    # Return nil for a message the provider does not own, which is nearly all
    # of them. The first non-nil answer wins, in provider order, and replaces
    # the user's text for that turn -- so a provider claiming a message is
    # taking responsibility for telling the agent what to do with it.
    module ChatTurnOrientation
      def self.included(base) = base.extend(self)
    end
  end
end
