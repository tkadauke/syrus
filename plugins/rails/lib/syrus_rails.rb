require_relative "syrus_rails/preview_provider"

# SyrusRails — Syrus plugin for Ruby on Rails repositories.
# Call SyrusRails.register! from an initializer (or require this file)
# to activate all Rails-specific extension points.
module SyrusRails
  def self.register!
    Syrus::PluginRegistry.register(:preview_provider, PreviewProvider.new)
  end
end
