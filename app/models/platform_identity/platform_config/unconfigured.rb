class PlatformIdentity::PlatformConfig::Unconfigured < PlatformIdentity::PlatformConfig::Base
  def configured?
    false
  end

  def instructions(_token)
    { text: "This platform is not yet configured." }
  end
end
