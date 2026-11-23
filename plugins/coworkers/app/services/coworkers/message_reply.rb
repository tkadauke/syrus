class Coworkers::MessageReply
  include Syrus::Host::ChatTurnFinalizer
  include Syrus::Host::ChatTurnOrientation

  NO_REPLY = "NO_REPLY"
  MENTION_CONTINUATION_SOURCES = %w[
    agent_question_answer
    authorization_continuation
    pending_action_notification
    pending_action_group_notification
    proposal_notification
  ].freeze

  def self.after_chat_turn(chat_session:, user_message:, turn_succeeded: false)
    if mention_metadata(chat_session, user_message)
      return new(chat_session:, user_message:).deliver_mention if turn_succeeded

      new(chat_session:, user_message:).fail_mention
      return
    end
    return unless turn_succeeded

    new(chat_session:, user_message:).deliver
  end

  def self.chat_turn_orientation(chat_session:, message:, user_note:)
    if (metadata = mention_metadata(chat_session, message))
      return <<~TEXT.strip
        #{user_note}

        Write the final, self-contained reply that the source chat will see. Your final assistant text is delivered there automatically; do not narrate that delivery.
      TEXT
    end
    metadata = incoming_metadata(message)
    return unless metadata

    remaining = [ Coworkers::MessageDispatcher::MAX_HOPS - metadata.fetch("hop_count").to_i, 0 ].max
    <<~TEXT.strip
      Incoming coworker message from @#{metadata.fetch("sender_handle")}:

      #{user_note}

      Write your reply for @#{metadata.fetch("sender_handle")}. Your final assistant text will be delivered to them automatically.
      #{remaining} #{"exchange".pluralize(remaining)} remain before the hop limit. Reply with only #{NO_REPLY} to end the exchange without sending or showing a reply.
    TEXT
  end

  def self.incoming_metadata(message)
    return unless message&.content.is_a?(Hash)
    return unless message.content["source"] == "coworker_message"

    metadata = message.content["coworker_message"]
    metadata if metadata.is_a?(Hash) && metadata["direction"] == "incoming"
  end
  private_class_method :incoming_metadata

  def self.mention_metadata(chat_session, message)
    return unless message&.content.is_a?(Hash)
    return message.content["coworker_mention"] if message.content["source"] == "coworker_mention"
    return unless message.content["source"].in?(MENTION_CONTINUATION_SOURCES)
    return unless Coworkers::Chat.exists?(chat_session: chat_session, role: "mention")

    prior = chat_session.messages.where(role: "user").where("id < ?", message.id).order(id: :desc).detect do |candidate|
      candidate.content.is_a?(Hash) && candidate.content["source"] == "coworker_mention"
    end
    prior&.content&.fetch("coworker_mention", nil)
  end
  private_class_method :mention_metadata

  def initialize(chat_session:, user_message:)
    @chat_session = chat_session
    @user_message = user_message
  end

  def deliver
    metadata = self.class.send(:incoming_metadata, user_message)
    return unless metadata

    reply = chat_session.messages.where(role: "assistant").where("id > ?", user_message.id).order(:id).last
    text = reply&.extract_text_from_content.to_s.strip
    if reply && (text.blank? || text == NO_REPLY)
      reply.destroy!
      return
    end
    return if text.blank?

    sender = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)&.coworker
    receiver = Coworkers::Coworker.find_by(id: metadata["sender_id"], owner_user_id: sender&.owner_user_id)
    return unless sender && receiver
    return unless claim_delivery!

    Coworkers::MessageDispatcher.call(
      sender: sender,
      receiver: receiver,
      text: text,
      delivery_context: {
        "origin_turn_id" => metadata["origin_turn_id"],
        "hop_count" => metadata.fetch("hop_count", 0).to_i + 1
      }
    )
  end

  def deliver_mention
    metadata = self.class.send(:mention_metadata, chat_session, user_message)
    return unless metadata && claim_mention_delivery!

    reply = chat_session.messages.where(role: "assistant").where("id > ?", user_message.id).order(:id).last
    text = reply&.extract_text_from_content.to_s.strip
    return if text.blank?

    link = Coworkers::Chat.includes(:coworker, :source_chat_session).find_by!(chat_session: chat_session, role: "mention")
    source_chat = link.source_chat_session
    delivered_reply = source_chat.messages.create!(
      role: "assistant",
      content: {
        "text" => text,
        "source" => "coworker_message",
        "origin_chat_session_id" => chat_session.id,
        "coworker_message" => {
          "direction" => "incoming", "sender_id" => link.coworker_id,
          "sender_handle" => link.coworker.handle,
          "origin_turn_id" => metadata["source_message_id"],
          "hop_count" => metadata.fetch("hop_count", 0).to_i + 1
        }
      },
      skip_turn_trigger: true
    )
    source_chat.touch(:last_message_at)
    source_chat.broadcast_controls

    roster_entry = Coworkers::ChatAgent.find_by(chat_session: source_chat, coworker: link.coworker)
    return unless roster_entry
    return if owner_facing_item_waiting?(source_chat)

    Coworkers::AfterReplyPolicy.for(roster_entry.after_reply).enqueue!(
      chat: source_chat,
      coworker: link.coworker,
      reply: delivered_reply,
      hop_count: metadata.fetch("hop_count", 0).to_i + 1
    )
  end

  def fail_mention
    link = Coworkers::Chat.includes(:coworker, :source_chat_session).find_by(chat_session: chat_session, role: "mention")
    Coworkers::MentionSession.fail!(source_message: Syrus::Host::ChatMessage.find_by(id: self.class.send(:mention_metadata, chat_session, user_message)&.fetch("source_message_id", nil)), coworker: link&.coworker, error: RuntimeError.new("mention turn failed"))
  end

  private

  attr_reader :chat_session, :user_message

  def owner_facing_item_waiting?(owner_chat)
    owner_chat.agent_questions.active.where(response_chat_session_id: chat_session.id).exists? ||
      owner_chat.proposals.proposed.where(response_chat_session_id: chat_session.id).exists? ||
      owner_chat.pending_actions.where(state: %w[queued pending confirming], origin: chat_session).exists?
  end

  def claim_delivery!
    user_message.with_lock do
      content = user_message.content.deep_dup
      metadata = content.fetch("coworker_message")
      return false if metadata["auto_reply_claimed"]

      metadata["auto_reply_claimed"] = true
      user_message.update!(content: content)
      true
    end
  end

  def claim_mention_delivery!
    user_message.with_lock do
      content = user_message.content.deep_dup
      metadata = content["coworker_mention"]
      if metadata
        return false if metadata["auto_reply_claimed"]

        metadata["auto_reply_claimed"] = true
      else
        return false if content["coworker_mention_reply_claimed"]

        content["coworker_mention_reply_claimed"] = true
      end
      user_message.update!(content: content)
      true
    end
  end
end
