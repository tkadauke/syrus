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
      :long_description,
      :homepage,
      :icon_url,
      :enabled,
      :default_enabled,
      :disableable,
      :category,
      :home_queue,
      :tick_interval,
      :config_schema,
      :depends_on,
      :optionally_depends_on,
      :conflicts_with,
      :prepare_priority,
      :hosts
    ) do
      def initialize(display_name: nil, description: nil, long_description: nil, homepage: nil, icon_url: nil, enabled: true, default_enabled: true, disableable: true, category: nil, home_queue: :default, tick_interval: nil, config_schema: [], depends_on: [], optionally_depends_on: [], conflicts_with: [], prepare_priority: 100, hosts: [], **) = super

      # Extension points this plugin hosts for others, qualified with its own
      # name: `hosts: [:parser]` on "test_insights" offers
      # "test_insights:parser". Core's points are simply the ones the kernel
      # hosts, and stay unqualified.
      def hosted_extension_points = Array(hosts).map { |point| "#{name}:#{point}" }

      def enabled? = enabled
      def default_enabled? = default_enabled
      def disableable? = disableable
    end
  end
end
