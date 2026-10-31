class Coworkers::MessageReply
  include Syrus::Plugin::ChatTurnFinalizer
  include Syrus::Plugin::ChatTurnOrientation

  NO_REPLY = "NO_REPLY"

  def self.after_chat_turn(chat_session:, user_message:)
    new(chat_session:, user_message:).deliver
  end

  def self.chat_turn_orientation(chat_session:, message:, user_note:)
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

  private

  attr_reader :chat_session, :user_message
end
