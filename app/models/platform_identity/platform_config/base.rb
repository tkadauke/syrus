class PlatformIdentity::PlatformConfig::Base
  # Platforms registered via the :platform_delivery plugin extension point
  # (see PlatformIdentity.available_platforms) fall back to Unconfigured
  # when they haven't supplied their own PlatformConfig subclass -- the
  # platform still shows up in Settings, just not yet connectable.
  def self.for(platform)
    {
      "telegram" => PlatformIdentity::PlatformConfig::Telegram,
      "slack" => PlatformIdentity::PlatformConfig::Slack
    }.fetch(platform.to_s) { PlatformIdentity::PlatformConfig::Unconfigured }.new
  end

  def configured?
    raise NotImplementedError
  end

  def instructions(_token)
    raise NotImplementedError
  end
end
