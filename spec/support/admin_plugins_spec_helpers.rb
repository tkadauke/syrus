module AdminPluginsSpec
  class AvailableProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "available"
    def self.display_name = "Available"
    def self.available? = true
  end

  class UnavailableProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "unavailable"
    def self.display_name = "Unavailable"
    def self.available? = false
  end

  class CustomInputSource < InputSource
    include Syrus::Plugin::InputSource
  end
end
