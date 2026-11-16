module PluginCli
  class Catalog
    def commands
      manifests.flat_map do |manifest|
        manifest.cli_commands.map do |command|
          command.except("handler").merge("plugin" => manifest.name)
        end
      end.sort_by { |command| [ command.fetch("path"), command.fetch("plugin") ] }
    end

    def find(plugin:, path:)
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin }
      raise UnknownPlugin unless manifest
      raise DisabledPlugin unless manifest.enabled?
      raise UnavailablePlugin unless Syrus::PluginRegistry.health.healthy?(manifest.name)

      command = manifest.cli_commands.find { |candidate| candidate.fetch("path") == path }
      raise UnknownCommand unless command
      [ manifest, command ]
    end

    private

    def manifests
      health = Syrus::PluginRegistry.health
      Syrus::PluginRegistry.all_plugins.select do |manifest|
        manifest.enabled? && health.healthy?(manifest.name) && manifest.cli_commands.any?
      end
    end

    UnknownPlugin = Class.new(StandardError)
    DisabledPlugin = Class.new(StandardError)
    UnavailablePlugin = Class.new(StandardError)
    UnknownCommand = Class.new(StandardError)
  end
end
