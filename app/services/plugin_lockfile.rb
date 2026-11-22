require "yaml"

module PluginLockfile
  module_function

  def export
    { "version" => 1, "plugins" => PluginInstallation.includes(plugin_release: :plugin_registry).order(:plugin_name).map do |installation|
      release = installation.plugin_release
      { "name" => release.name, "version" => release.version, "digest" => release.content_digest, "source" => release.source,
        "registry" => release.plugin_registry&.name }.compact
    end }.to_yaml
  end

  def import!(contents, actor:)
    data = YAML.safe_load(contents, permitted_classes: [], aliases: false)
    raise ArgumentError, "unsupported plugin lockfile" unless data.is_a?(Hash) && data["version"] == 1 && data["plugins"].is_a?(Array)

    installer = PluginInstaller.new(actor:)
    data["plugins"].map do |entry|
      releases = PluginRelease.where(name: entry.fetch("name"), version: entry.fetch("version"),
        content_digest: entry.fetch("digest"), source: entry.fetch("source"))
      registry = entry["registry"]
      releases = releases.joins(:plugin_registry).where(plugin_registries: { name: registry }) if registry.present?
      release = releases.first!
      installer.stage_release!(release.name, version: release.version, digest: release.content_digest,
        source: release.source, registry:)
    end
  end
end
