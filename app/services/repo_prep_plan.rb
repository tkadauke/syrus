require "yaml"

# Resolves the list of shell commands Syrus should run in a
# freshly-cloned workspace BEFORE handing off to the agent.
# Source of truth, in order of precedence:
#
#   1. `.syrus.yml` at the repo root — operator-authored.
#       prepare:
#         - bundle install
#         - npm install
#      `prepare: []` or `prepare: false` opts out entirely.
#   2. Auto-detect via registered `:prepare_detector` plugins
#      (Syrus::PluginRegistry), unioned with the legacy hardcoded
#      Ruby/Node fallback below. Every matching detector/group
#      contributes commands — a Rails+React repo gets both
#      `bundle install` and `npm ci`, not just the first hit.
#
# Returns an Array of String commands (possibly empty). Pure;
# no side effects. The Steps::Prepare handler is what actually
# runs them.
class RepoPrepPlan
  CONFIG_FILE = ".syrus.yml".freeze

  # Legacy fallback auto-detect groups, used for signals not yet covered by a
  # registered :prepare_detector plugin. Each inner group is a
  # package-manager priority list for ONE ecosystem — only the first
  # matching file within a group contributes a command, mirroring how a
  # single plugin picks exactly one package manager internally. Different
  # groups still union across ecosystems.
  #
  # TEMPORARY: these entries are removed once the `ruby` and `javascript`
  # plugins register their own :prepare_detector providers for the same
  # signals (EPIC-242).
  AUTO_DETECT = [
    [
      [ "Gemfile", "bundle install" ]
    ],
    [
      [ "yarn.lock",         "yarn install --frozen-lockfile" ],
      [ "pnpm-lock.yaml",    "pnpm install --frozen-lockfile" ],
      [ "package-lock.json", "npm ci" ],
      [ "package.json",      "npm install" ]
    ]
  ].freeze

  # Flat [file, command] pairs across every legacy group, for callers that
  # want the full reference table (e.g. onboarding/audit skill instructions)
  # rather than the "first match per group" resolution `AUTO_DETECT` groups
  # are structured for.
  FLAT_AUTO_DETECT = AUTO_DETECT.flatten(1).freeze

  Result = Data.define(:commands, :source, :note) do
    # Auto-detected plans are a *guess* — Syrus inferred the command
    # from a lockfile, the repo never asked for it. Steps::Prepare
    # soft-fails these (warn + hand off to the agent anyway) so a wrong
    # guess can't wedge onboarding. Explicit `.syrus.yml` plans, by
    # contrast, are operator intent and hard-fail. The source string is
    # the discriminator: `from_auto_detect` always prefixes "auto-detect".
    def guessed?
      source.to_s.start_with?("auto-detect")
    end
  end

  def self.for(workspace_path)
    new(workspace_path).resolve
  end

  def initialize(workspace_path)
    @path = Pathname.new(workspace_path)
  end

  def resolve
    if config_present?
      from_config
    else
      from_auto_detect
    end
  end

  private

  def config_present?
    @path.join(CONFIG_FILE).exist?
  end

  def from_config
    config = SyrusYml.load_repo(@path)
    raw = config.prepare

    case raw
    when Array
      commands = raw.map(&:to_s).map(&:strip).reject(&:empty?)
      Result.new(commands: commands, source: ".syrus.yml",
                 note: commands.empty? ? "prepare: [] — no commands" : nil)
    when false, nil
      Result.new(commands: [], source: ".syrus.yml",
                 note: "prepare: #{raw.inspect} — opted out")
    else
      Result.new(commands: [], source: ".syrus.yml",
                 note: "prepare: must be an array of strings (got #{raw.class})")
    end
  rescue SyrusYml::ParseError => e
    Result.new(commands: [], source: ".syrus.yml",
               note: e.message)
  end

  def from_auto_detect
    plugin_matches = plugin_detector_matches
    legacy_matches = legacy_auto_detect_matches
    matches = plugin_matches + legacy_matches

    if matches.empty?
      Result.new(commands: [], source: "auto-detect", note: "no recognized signals — skipping")
    else
      commands = matches.flat_map { |_label, cmds| cmds }
      labels = matches.map(&:first)
      Result.new(commands: commands, source: "auto-detect (#{labels.join(', ')})", note: nil)
    end
  end

  # [label, commands] pairs from every enabled :prepare_detector plugin whose
  # detect? matches, in prepare_priority order (see PluginRegistry).
  def plugin_detector_matches
    Syrus::PluginRegistry.providers_for(:prepare_detector).filter_map do |detector|
      next unless detector.detect?(@path.to_s)

      commands = Array(detector.prepare_commands(@path.to_s))
      next if commands.empty?

      [ detector.name, commands ]
    end
  end

  # [file, [command]] pairs for the first matching file in each legacy group.
  def legacy_auto_detect_matches
    AUTO_DETECT.filter_map do |group|
      file, command = group.find { |f, _cmd| @path.join(f).exist? }
      next unless file

      [ file, [ command ] ]
    end
  end
end
