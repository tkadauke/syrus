require "yaml"

module PluginLockfile
  module_function

  def export
    { "version" => 1, "plugins" => PluginInstallation.includes(:plugin_release).order(:plugin_name).map do |installation|
      release = installation.plugin_release
      { "name" => release.name, "version" => release.version, "digest" => release.content_digest, "source" => release.source }
    end }.to_yaml
  end

  def import!(contents, actor:)
    data = YAML.safe_load(contents, permitted_classes: [], aliases: false)
    raise ArgumentError, "unsupported plugin lockfile" unless data.is_a?(Hash) && data["version"] == 1 && data["plugins"].is_a?(Array)

    data["plugins"].map do |entry|
      release = PluginRelease.find_by!(name: entry.fetch("name"), version: entry.fetch("version"),
        content_digest: entry.fetch("digest"), source: entry.fetch("source"))
      PluginChange.pending.where(plugin_name: release.name).update_all(status: "superseded", updated_at: Time.current)
      PluginChange.create!(plugin_name: release.name,
        action: PluginInstallation.exists?(plugin_name: release.name) ? "update" : "install",
        plugin_release: release, capability_manifest: {}, status: "pending", staged_by: actor)
    end
  end
end
