class Coworkers::MentionDeliveryJob < Syrus::Host::PluginJob
  plugin :coworkers
  queue_as :chat

  discard_on ActiveRecord::RecordNotFound

  def perform(source_message_id, coworker_id)
    source_message = nil
    source_message = Syrus::Host::ChatMessage.find(source_message_id)
    coworker = Coworkers::Coworker.find(coworker_id)
    source_chat = source_message.chat_session
    return unless Coworkers::ChatAgent.exists?(chat_session: source_chat, coworker: coworker)
    return unless delivery_allowed?(source_message, coworker)

    link = Coworkers::MentionSession.find_or_create!(coworker:, source_chat:)
    message = Coworkers::MentionSession.deliver!(link:, source_message:)
    Syrus::Host::ChatTurnJob.perform_later(link.chat_session_id, message.id)
    source_chat.broadcast_controls
  rescue StandardError => error
    Coworkers::MentionSession.fail!(source_message:, coworker:, error:)
    raise
  end

  private

  def delivery_allowed?(source_message, receiver)
    metadata = source_message.content.to_h["coworker_message"].to_h
    hop_count = metadata.fetch("hop_count", 0).to_i
    return refuse!(source_message, receiver, "coworker message chain reached its #{Coworkers::MessageDispatcher::MAX_HOPS}-hop limit") if hop_count >= Coworkers::MessageDispatcher::MAX_HOPS

    sender_id = metadata["sender_id"]
    return true unless sender_id

    sender = Coworkers::Coworker.find_by(id: sender_id, owner_user_id: receiver.owner_user_id)
    return false unless sender
    limit = Coworkers::MessageRateLimiter.reserve(sender:, receiver:)
    return true if limit.allowed?

    refuse!(source_message, receiver, "coworker message rate limit reached; try again in #{limit.retry_after_seconds} seconds")
  end

  def refuse!(source_message, receiver, reason)
    source_message.chat_session.messages.create!(
      role: "system",
      content: { "text" => "Mention of @#{receiver.handle} was not delivered: #{reason}", "source" => "coworker_mention_refused" },
      skip_turn_trigger: true
    )
    false
  end
end
