module Syrus
  module Plugin
    # Immutable record holding one plugin's registration details.
    # Returned by PluginRegistry.all_plugins.
    Manifest = Data.define(:name, :version, :provides, :metadata)
  end
end
