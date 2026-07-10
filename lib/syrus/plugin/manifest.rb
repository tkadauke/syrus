module Syrus
  module Plugin
    # Immutable record holding one plugin's registration details.
    # Returned by PluginRegistry.all_plugins; `enabled` reflects current DB state.
    Manifest = Data.define(:name, :version, :provides, :metadata, :description, :homepage, :icon_url, :enabled) do
      def initialize(description: nil, homepage: nil, icon_url: nil, enabled: true, **) = super

      def enabled? = enabled
    end
  end
end
