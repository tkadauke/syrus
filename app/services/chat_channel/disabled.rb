module ChatChannel
  class Disabled
    def send_message(run:, text:)
      raise ConfigurationError, "operator chat is disabled for this repository"
    end
  end
end
