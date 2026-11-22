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

    installer = PluginInstaller.new(actor:)
    data["plugins"].map do |entry|
      release = PluginRelease.find_by!(name: entry.fetch("name"), version: entry.fetch("version"),
        content_digest: entry.fetch("digest"), source: entry.fetch("source"))
      installer.stage_release!(release.name, version: release.version, digest: release.content_digest, source: release.source)
    end
  end
end
