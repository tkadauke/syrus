# Proposal-outcome agent notification extracted from ChatsController: posts a
# system message telling the agent a proposal was confirmed/rejected and
# builds its control-content payload. Kept private on include.
module ChatProposalOutcomeNotice
  private

  def notify_agent_of_proposal_outcome(message)
    chat_session = message.chat_session
    return unless chat_session

    deferred = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(chat_session.id)

      if chat.agent_busy?
        # An agent is actively running — don't interrupt it. Enqueue a deferred
        # notice that ChatQueuedMessagePromoter will deliver after the turn ends.
        # The content carries the same proposal_outcome source/acknowledgment fields
        # that ChatTurnJob uses to detect and render a lightweight acknowledgment.
        chat.chat_queued_messages.create!(content: message.content)
        deferred = true
      end

      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence
      )
    end

    enqueue_chat_turn(chat_session, message) unless deferred
  end

  def proposal_outcome_control_content(proposal, text:, outcome:)
    {
      "text" => text,
      "source" => ChatProposalOutcomeNotification::SOURCE,
      "outcome" => outcome.to_s,
      "acknowledgment" => ChatProposalOutcomeNotification.acknowledgment(proposal, outcome: outcome)
    }
  end
end
