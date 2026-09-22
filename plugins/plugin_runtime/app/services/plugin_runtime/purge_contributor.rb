module PluginRuntime
  # Container-backed plugins keep data in volumes the runtime manager owns,
  # outside the database. `plugin:purge[name]` asks this for them so purging
  # a plugin removes its volumes too. See Syrus::Plugin::PurgeContributor.
  class PurgeContributor
    include Syrus::Plugin::PurgeContributor

    def self.purge_report(plugin_name, configuration: Configuration.current)
      return [] unless configuration.managed?

      client(configuration).volumes.select { |volume| volume["plugin"] == plugin_name.to_s }.map do |volume|
        size = volume["size_bytes"] ? " (#{ActiveSupport::NumberHelper.number_to_human_size(volume['size_bytes'])})" : ""
        "volume #{volume['name']}#{size}"
      end
    end

    def self.purge!(plugin_name, configuration: Configuration.current)
      return [] unless configuration.managed?

      client(configuration).purge_plugin(plugin_name).map { |name| "volume #{name}" }
    end

    def self.client(configuration)
      Client.new(url: configuration.manager_url, token: configuration.manager_token)
    end
  end
end
