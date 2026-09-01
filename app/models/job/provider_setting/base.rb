class Job::ProviderSetting::Base
  DEFAULT_VALUE = "default".freeze

  def self.values
    ([ DEFAULT_VALUE ] + User.agent_providers).uniq
  end

  def self.for(value)
    setting = value.to_s
    return Job::ProviderSetting::Default.new if setting == DEFAULT_VALUE
    return Provider.new(setting) if User.agent_providers.include?(setting)

    raise ArgumentError, "unknown job provider setting: #{value.inspect}"
  end

  def resolve(_job)
    raise NotImplementedError
  end

  class Provider < Job::ProviderSetting::Base
    def initialize(provider)
      @provider = provider.to_s
    end

    def resolve(_job) = @provider
  end
end
