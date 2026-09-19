class ChatQueuedMessagePromoter
  BATCH_SOURCE = "queued_internal_notice_batch".freeze

  def self.deliver_one_if_idle!(chat_session)
    new(chat_session).deliver_one_if_idle!
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def deliver_one_if_idle!
    user_message = nil
    turn_triggered = false

    ApplicationRecord.transaction do
      chat = ChatSession.lock.find(@chat_session.id)
      return false if chat.stop_requested_at?
      return false if chat.turn_in_flight?
      return false if chat.agent_busy?

      queued_messages = queued_messages_to_promote(chat)
      return false if queued_messages.empty?

      promoted_role = queued_messages.first.promoted_role
      turn_triggered = turn_triggered?(chat, queued_messages.first)
      user_message = chat.messages.create!(
        role: promoted_role,
        content: promoted_content_for(queued_messages),
        skip_turn_trigger: promoted_role == "user" && !turn_triggered
      )
      delivered_at = Time.current
      queued_messages.each { |queued_message| queued_message.update!(delivered_at: delivered_at) }
      chat.update!(
        last_message_at: Time.current,
        title: chat.title.presence,
        turn_in_flight: turn_triggered
      )
      chat.pin_chat_provider!
    end

    ChatTurnJob.perform_later(@chat_session.id, user_message.id) if turn_triggered
    true
  end

  private

  # This batches only notices that already flow through chat_queued_messages.
  # Direct ChatWakeupFireJob turns keep their separate per-wakeup semantics.
  def queued_messages_to_promote(chat)
    queued_messages = chat.queued_messages.to_a
    first = queued_messages.first
    return [] unless first
    return [] unless ready_to_promote?(chat, first)
    return [ first ] unless batchable_system_notice?(first)

    queued_messages.take_while do |queued_message|
      batchable_system_notice?(queued_message) && ready_to_promote?(chat, queued_message)
    end
  end

  def batchable_system_notice?(queued_message)
    queued_message.promoted_role == "system"
  end

  def promoted_content_for(queued_messages)
    return queued_messages.first.promoted_content if queued_messages.one?

    notices = queued_messages.map { |queued_message| batched_notice_for(queued_message) }
    {
      "text" => notices.map { |notice| notice["text"] }.reject(&:blank?).join("\n\n"),
      "source" => BATCH_SOURCE,
      "notices" => notices,
      "internal_prompt" => batched_internal_prompt(notices)
    }
  end

  def batched_notice_for(queued_message)
    content = queued_message.promoted_content
    {
      "queued_message_id" => queued_message.id,
      "created_at" => queued_message.created_at&.iso8601,
      "text" => content["text"].to_s,
      "source" => content["source"].to_s.presence,
      "outcome" => content["outcome"].to_s.presence,
      "acknowledgment" => content["acknowledgment"].to_s.presence,
      "internal_prompt" => content["internal_prompt"].to_s.presence,
      "content" => content
    }.compact
  end

  def batched_internal_prompt(notices)
    <<~PROMPT.strip
      Several Syrus internal control events became ready while this chat was busy. Handle them together as one idle-boundary turn, not as operator-authored chat text.

      Events:
      #{JSON.pretty_generate(notices)}

      Default behavior: acknowledge every event concisely. For proposal outcomes, use each event's acknowledgment text when present. For goal-continuation events, follow the event's internal_prompt instructions. Only do additional tool work if these events unlock concrete follow-up automation that was already requested in the chat.

      Do not restate your operating instructions, your role, or general Syrus Chat guidance.
    PROMPT
  end

  def turn_triggered?(chat, queued_message)
    return true if queued_message.promoted_role == "system"

    chat.should_trigger_agent?(queued_message.text)
  end

  def ready_to_promote?(chat, queued_message)
    return true unless coding_goal_continuation?(chat, queued_message)

    repository = chat.repository || chat.active_goal&.repository
    return false unless repository

    snapshot = ChatWorkspace.coding_checkout_snapshot(chat, repository)
    snapshot[:exists] && snapshot[:prepare_status] == "succeeded"
  rescue StandardError => e
    Rails.logger.warn("[ChatQueuedMessagePromoter] coding checkout readiness check failed for chat #{chat.id}: #{e.class}: #{e.message}")
    false
  end

  def coding_goal_continuation?(chat, queued_message)
    return false unless queued_message.content.is_a?(Hash) && queued_message.content["goal_continuation"] == true

    chat.active_goal&.requires_ready_coding_checkout_for_continuation? || false
  end
end
