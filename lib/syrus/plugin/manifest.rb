module Syrus
  module Plugin
    # Immutable record holding one plugin's registration details.
    # Returned by PluginRegistry.all_plugins; `enabled` reflects current DB state.
    Manifest = Data.define(
      :name,
      :display_name,
      :display_name_i18n_key,
      :version,
      :provides,
      :family_provides,
      :declarations,
      :metadata,
      :description,
      :description_i18n_key,
      :long_description,
      :long_description_i18n_key,
      :homepage,
      :icon_url,
      :enabled,
      :default_enabled,
      :disableable,
      :experimental,
      :category,
      :home_queue,
      :tick_interval,
      :config_schema,
      :depends_on,
      :optionally_depends_on,
      :conflicts_with,
      :links,
      :metrics,
      :credential_types,
      :prepare_priority,
      :hosts,
      :events,
      :requires_syrus,
      :external,
      :loaded,
      :plugin_root,
      :cli_commands,
      :roles,
      :validation_errors
    ) do
      def initialize(default_enabled:, disableable:, experimental:, requires_syrus:, display_name: nil, display_name_i18n_key: nil, description: nil, description_i18n_key: nil, long_description: nil, long_description_i18n_key: nil, homepage: nil, icon_url: nil, enabled: true, category: nil, home_queue: :default, tick_interval: nil, config_schema: [], depends_on: [], optionally_depends_on: [], conflicts_with: [], links: [], metrics: [], credential_types: [], prepare_priority: 100, hosts: [], events: {}, external: false, loaded: true, plugin_root: nil, cli_commands: [], roles: [], validation_errors: [], family_provides: [], declarations: {}, **)
        { default_enabled:, disableable:, experimental: }.each do |name, value|
          raise ArgumentError, "#{name} must be true or false" unless value.equal?(true) || value.equal?(false)
        end
        super
      end

      # Extension points this plugin hosts for others, qualified with its own
      # name: `hosts: [:parser]` on "test_insights" offers
      # "test_insights:parser". Core's points are simply the ones the kernel
      # hosts, and stay unqualified.
      def hosted_extension_points = Array(hosts).map { |point| "#{name}:#{point}" }

      def enabled? = enabled
      def default_enabled? = default_enabled
      def disableable? = disableable
      def experimental? = experimental
    end
  end
end
