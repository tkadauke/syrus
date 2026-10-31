class Coworkers::MessageDispatcher
  MAX_HOPS = 3

  Result = Data.define(:delivered, :error) do
    def delivered? = delivered
  end

  def self.call(sender:, receiver:, text:, delivery_context:)
    new(sender:, receiver:, text:, delivery_context:).call
  end

  def initialize(sender:, receiver:, text:, delivery_context:)
    @sender = sender
    @receiver = receiver
    @text = text.to_s.strip
    @delivery_context = delivery_context
  end

  def call
    return refused("coworkers must have the same owner") unless sender.owner_user_id == receiver.owner_user_id
    return refused("a coworker cannot message itself") if sender.id == receiver.id
    return refused("@#{receiver.handle} is #{receiver.state} and cannot receive messages") unless receiver.state == "active"
    return refused("@#{sender.handle} is #{sender.state} and cannot send messages") unless sender.state == "active"

    if delivery_context.fetch("hop_count") > MAX_HOPS
      return refused("coworker message chain reached its #{MAX_HOPS}-hop limit")
    end

    rate_limit = Coworkers::MessageRateLimiter.reserve(sender: sender, receiver: receiver)
    unless rate_limit.allowed?
      return refused(
        "coworker message rate limit reached for @#{sender.handle} and @#{receiver.handle}; " \
          "try again in #{rate_limit.retry_after_seconds} seconds",
        status: "rate_limited"
      )
    end

    delivery = Coworkers::MessageDeliveryJob.perform_later(sender.id, receiver.id, text, delivery_context)
    return Result.new(delivered: false, error: "the coworker message could not be queued") unless delivery

    Result.new(delivered: true, error: nil)
  end

  private

  attr_reader :sender, :receiver, :text, :delivery_context

  def refused(reason, status: "refused")
    sender.coworker_chats.find_by!(role: "main").chat_session.messages.create!(
      role: "system",
      content: {
        "text" => "Message to @#{receiver.handle} was not delivered: #{reason}",
        "source" => "coworker_message",
        "coworker_message" => {
          "direction" => "outgoing", "status" => status,
          "receiver_id" => receiver.id, "receiver_handle" => receiver.handle,
          "origin_turn_id" => delivery_context["origin_turn_id"],
          "hop_count" => delivery_context["hop_count"]
        }
      },
      skip_turn_trigger: true
    )
    Result.new(delivered: false, error: reason)
  end
end
