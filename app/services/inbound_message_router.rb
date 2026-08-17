class InboundMessageRouter
  Result = Data.define(:status, :session)

  def initialize(platform:, external_id:, external_handle:, message_text:)
    @platform = platform
    @external_id = external_id
    @external_handle = external_handle
    @message_text = message_text
  end

  def call
    identity = PlatformIdentity.find_by(platform: @platform, external_id: @external_id)
    return Result.new(status: :not_linked, session: nil) unless identity

    user = identity.user
    session = ChatSession.for_platform(user: user, platform: @platform)

    message = session.messages.create!(
      role: "user",
      sender_user: user,
      content: { "text" => @message_text }
    )

    if session.trigger_policy == "speak_when_spoken_to" && session.should_trigger_agent?(@message_text)
      ChatTurnJob.perform_later(session.id, message.id)
    end

    Result.new(status: :ok, session: session)
  end
end
