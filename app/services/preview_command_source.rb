require "syrus/plugin/preview_provider"

# Resolves preview start-command configuration for a repository workspace in
# priority order:
#
#   1. `.syrus.yml` `preview:` section (operator-explicit config)
#   2. A registered `:preview_provider` plugin that auto-detects the repo
#   3. nil — no preview available; the Start Preview button should be hidden
#
# Returns a PreviewCommandSource::Config value object, or nil.
#
# `start_command_for` is a callable that accepts `port:` and returns a shell
# command string. This defers port resolution to spawn time so the allocator
# can pick a free port and hand it off in one step.
class PreviewCommandSource
  # `start_command_for` — callable(port:) → String
  Config = Data.define(:start_command_for, :seed_command, :health_check_path, :log_paths)

  def initialize(workspace_path)
    @workspace_path = workspace_path
  end

  def resolve
    from_syrus_yml || from_plugin
  end

  private

  def from_syrus_yml
    config = SyrusYml.load_repo(@workspace_path)
    return nil unless config.preview

    p = config.preview
    Config.new(
      start_command_for: ->(port:) { p.start.gsub("${PORT}", port.to_s).gsub("$PORT", port.to_s) },
      seed_command:      p.seed,
      health_check_path: p.health_check,
      log_paths:         p.logs
    )
  rescue SyrusYml::ParseError, Errno::ENOENT
    nil
  end

  def from_plugin
    provider = Syrus::Plugin::PreviewProvider.for_repo(@workspace_path)
    return nil unless provider

    Config.new(
      start_command_for: ->(port:) { provider.start_command(port: port) },
      seed_command:      provider.seed_command,
      health_check_path: provider.health_check_path,
      log_paths:         provider.log_paths
    )
  end
end
