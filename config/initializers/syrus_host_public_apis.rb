Rails.application.config.to_prepare do
  Syrus::Host::PublicApis.install!
end
