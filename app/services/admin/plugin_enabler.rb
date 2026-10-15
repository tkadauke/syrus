module Admin
  class PluginEnabler
    class ExperimentalPluginsBlocked < StandardError
      attr_reader :plugins

      def initialize(plugins)
        @plugins = plugins
        super("This plugin is available in this Syrus build, but this instance has not enabled beta mode.")
      end
    end

    def self.enable!(plugin)
      new(plugin).enable!
    end

    def initialize(plugin, manifests: Syrus::PluginRegistry.all_plugins)
      @plugin = plugin
      @manifests = manifests
    end

    def enable!
      raise ExperimentalPluginsBlocked, blocked_experimental_plugins if blocked_experimental_plugins.any?

      ActiveRecord::Base.transaction do
        plugin.update!(enabled: true) unless plugin.enabled?
        PluginRecord.where(name: dependency_names).find_each do |record|
          record.update!(enabled: true) unless record.enabled?
        end
      end

      plugin
    end

    private

    attr_reader :plugin, :manifests

    def dependency_names
      @dependency_names ||= manifest ? PluginDependencyGraph.new(manifests).dependencies_for(manifest.name) : []
    end

    def manifest
      @manifest ||= manifests.find { |candidate| candidate.name == plugin.name }
    end

    def blocked_experimental_plugins
      return [] if AppSetting.beta_mode_enabled?

      by_name = manifests.index_by(&:name)
      [ plugin.name, *dependency_names ].filter_map { |name| by_name[name] }.select(&:experimental?)
    end
  end
end
