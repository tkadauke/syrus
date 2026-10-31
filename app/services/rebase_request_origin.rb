class RebaseRequestOrigin
  VALUES = %w[system user chat_agent].freeze

  def self.for(value)
    {
      "system" => System,
      "user" => User,
      "chat_agent" => ChatAgent
    }.fetch(value.to_s) { raise ArgumentError, "unknown rebase request origin: #{value.inspect}" }.new
  end

  def patient? = false

  class System < RebaseRequestOrigin
    def patient? = true
  end

  class User < RebaseRequestOrigin; end
  class ChatAgent < RebaseRequestOrigin; end
end
