module Syrus
  module Plugin
    # Immutable record holding one plugin's registration details.
    # Returned by PluginRegistry.all_plugins; `enabled` reflects current DB state.
    Manifest = Data.define(
      :name,
      :display_name,
      :version,
      :provides,
      :metadata,
      :description,
      :homepage,
      :icon_url,
      :enabled,
      :default_enabled,
      :disableable,
      :category,
      :home_queue,
      :tick_interval,
      :config_schema
    ) do
      def initialize(display_name: nil, description: nil, homepage: nil, icon_url: nil, enabled: true, default_enabled: true, disableable: true, category: nil, home_queue: :default, tick_interval: nil, config_schema: [], **) = super

      def enabled? = enabled
      def default_enabled? = default_enabled
      def disableable? = disableable
    end
  end
end
