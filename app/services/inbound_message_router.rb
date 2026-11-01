require "digest"

class InboundMessageRouter
  Result = Data.define(:status, :session)
  IdempotencyConflict = Class.new(StandardError)

  def initialize(platform:, external_id:, external_handle:, message_text:, native_message_id: nil, conversation_id: nil)
    @platform = platform
    @external_id = external_id
    @external_handle = external_handle
    @message_text = message_text
    @native_message_id = native_message_id.presence
    @conversation_id = conversation_id.presence
  end

  def call
    identity = PlatformIdentity.find_by(platform: @platform, external_id: @external_id)
    return Result.new(status: :not_linked, session: nil) unless identity

    user = identity.user
    session = ChatSession.for_platform(user: user, platform: @platform)

    message, turn_triggered = create_message(session:, user:)

    ChatTurnJob.perform_later(session.id, message.id) if message.previously_new_record? && turn_triggered

    Result.new(status: :ok, session: session)
  end

  private

  def create_message(session:, user:)
    mentions = session.resolve_mentions(@message_text)
    turn_triggered = session.trigger_policy == "speak_when_spoken_to" && session.should_trigger_agent?(mentions)
    attributes = {
      role: "user",
      sender_user: user,
      content: { "text" => @message_text },
      mentions: mentions,
      skip_turn_trigger: !turn_triggered
    }

    return [ session.messages.create!(**attributes), turn_triggered ] unless @native_message_id && @conversation_id

    key = provider_idempotency_key
    digest = Digest::SHA256.hexdigest(JSON.generate(attributes.fetch(:content)))
    receipt = claim_receipt!(user:, key:, digest:)
    return [ receipt.chat_message, turn_triggered ] if receipt.chat_message

    message = nil
    ApplicationRecord.transaction do
      receipt.lock!
      if receipt.chat_message
        message = receipt.chat_message
      else
        message = session.messages.create!(**attributes, client_idempotency_key: key)
        receipt.update!(chat_session: session, chat_message: message, response_status: 200)
      end
    end
    [ message, turn_triggered ]
  end

  def claim_receipt!(user:, key:, digest:)
    ChatIngressReceipt.transaction(requires_new: true) do
      ChatIngressReceipt.create!(
        sender_user: user,
        idempotency_key: key,
        operation: "platform_message",
        payload_digest: digest
      )
    end
  rescue ActiveRecord::RecordNotUnique
    receipt = ChatIngressReceipt.find_by!(sender_user: user, idempotency_key: key)
    raise IdempotencyConflict unless receipt.operation == "platform_message" && receipt.payload_digest == digest

    receipt
  end

  def provider_idempotency_key
    namespace = [ @platform, @conversation_id, @external_id, @native_message_id ]
    "platform:#{@platform}:#{Digest::SHA256.hexdigest(namespace.join("\0"))}"
  end
end
