Rails.application.config.to_prepare do
  Syrus::Host::PublicApis.install!
  Syrus::PluginLoader.scan_external_plugins!
end
