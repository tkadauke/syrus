module AuthorizationContinuations
  class ChatOrigin < Origin
    def self.accepts?(origin) = origin.is_a?(ChatSession)

    def resumable?
      !origin.deleted? && !origin.stop_requested_at?
    end

    def deliver!(payload)
      origin.chat_queued_messages.create!(
        content: {
          "text" => payload["outcome"] == "approved" ? "Permission granted. Continuing..." : "Permission denied. Continuing...",
          "internal_prompt" => Prompts::AuthorizationContinuation.new(payload).to_s,
          "requested_by" => "authorization",
          "source" => "authorization_continuation",
          "authorization_continuation" => true
        }
      )
    end

    def dispatch!
      ChatQueuedMessagePromoter.deliver_one_if_idle!(origin)
    end
  end
end
