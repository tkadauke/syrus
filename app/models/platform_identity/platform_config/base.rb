class PlatformIdentity::PlatformConfig::Base
  CORE_CONFIGS = {
    "slack" => -> { PlatformIdentity::PlatformConfig::Slack }
  }.freeze

  # Core platforms (slack) resolve to a hardcoded config class.
  # Platforms registered via the :platform_delivery plugin extension point
  # (see PlatformIdentity.available_platforms) resolve to their provider's
  # .platform_config_class when supplied; otherwise they fall back to
  # Unconfigured -- the platform still shows up in Settings, just not yet
  # connectable.
  def self.for(platform)
    key = platform.to_s
    klass = CORE_CONFIGS[key]&.call || plugin_config_class(key) || PlatformIdentity::PlatformConfig::Unconfigured
    klass.new
  end

  def self.plugin_config_class(platform)
    provider = Syrus::PluginRegistry.providers_for(:platform_delivery)
      .find { |p| p.platform_key.to_s == platform }
    provider&.platform_config_class
  end

  def configured?
    raise NotImplementedError
  end

  def instructions(_token)
    raise NotImplementedError
  end
end
