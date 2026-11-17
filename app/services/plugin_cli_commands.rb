# frozen_string_literal: true

class PluginCliCommands
  Error = Data.define(:code, :message, :status)

  def self.catalog
    healthy_manifests.flat_map(&:cli_commands).sort_by { |command| [ command.plugin, command.path ] }
  end

  def self.find(plugin:, path:)
    manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin.to_s }
    return Error.new(code: "plugin_not_found", message: I18n.t("api.cli_commands.errors.plugin_not_found"), status: :not_found) unless manifest
    unless manifest.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)
      return Error.new(code: "plugin_disabled", message: I18n.t("api.cli_commands.errors.plugin_disabled"), status: :not_found)
    end

    command = manifest.cli_commands.find { |candidate| candidate.path == Array(path).map(&:to_s) }
    command || Error.new(code: "command_not_found", message: I18n.t("api.cli_commands.errors.command_not_found"), status: :not_found)
  end

  def self.healthy_manifests
    health = Syrus::PluginRegistry.health
    Syrus::PluginRegistry.all_plugins.select { |manifest| manifest.enabled? && health.healthy?(manifest.name) }
  end
  private_class_method :healthy_manifests
end
