module Coworkers
  class AfterReplyPolicy
    def self.for(name)
      { "quiet" => Quiet, "wake" => Wake }.fetch(name.to_s).new
    rescue KeyError
      raise ArgumentError, "unknown coworker after-reply policy"
    end

    class Quiet < AfterReplyPolicy
      def enqueue!(**) = false
    end

    class Wake < AfterReplyPolicy
      SOURCE = "coworker_mention_followup".freeze

      def enqueue!(chat:, coworker:, reply:, hop_count:)
        return false if hop_count >= Coworkers::MessageDispatcher::MAX_HOPS
        return false unless Coworkers::AfterReplyRateLimiter.reserve(chat:, coworker:).allowed?

        chat.chat_queued_messages.create!(
          content: {
            Syrus::Host::ChatQueuedMessageRecord::INTERNAL_ROLE_KEY => "system",
            "text" => "@#{coworker.handle} replied to the mention.",
            "source" => SOURCE,
            "coworker_reply_message_id" => reply.id,
            "coworker_id" => coworker.id,
            "hop_count" => hop_count,
            "internal_prompt" => <<~PROMPT.strip
              A rostered coworker replied to the owner's mention. React to the reply in context.
              Do not mention @#{coworker.handle} again merely to acknowledge or repeat the reply.
              Mention that coworker again only when your next message adds a concrete question,
              correction, or task that genuinely needs another response.
            PROMPT
          }
        )
        Syrus::Host::ChatQueuedMessagePromoter.deliver_one_if_idle!(chat)
      end
    end
  end
end
