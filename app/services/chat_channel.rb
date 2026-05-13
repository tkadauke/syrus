module ChatChannel
  class ConfigurationError < StandardError; end

  CHANNELS = {
    "in_syrus" => -> { ChatChannel::InSyrus },
    "telegram" => -> { ChatChannel::Telegram }
  }.freeze

  def self.for(repository)
    channel = repository.allow_operator_chat.to_s
    klass = CHANNELS[channel]&.call
    raise ConfigurationError, "operator chat is not enabled for #{repository.slug}" unless klass

    klass.new
  end
end
