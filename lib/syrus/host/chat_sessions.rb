require "forwardable"

module Syrus
  module Host
    # Chat session lookups and creation, the first-turn enqueue, and the one
    # hook plugins use to extend the chat session model. Turns, broadcasts,
    # and other associations are not promised.
    module ChatSessions
      extend SingleForwardable

      def_delegators "::ChatSession", :where, :active, :find, :find_by, :create!, :fallback_title_for

      def self.effort_levels = ::ChatSession::EFFORT_LEVELS

      def self.enqueue_turn(chat, message) = ::ChatSessions::Creator.enqueue_turn(chat, message)

      # Evaluates the block against the chat session class (prepend, has_one,
      # define_method). The caller owns removing what it added.
      def self.extend_model(&block) = ::ChatSession.class_eval(&block)
    end
  end
end
