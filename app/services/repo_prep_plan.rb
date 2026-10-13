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
#      (Syrus::PluginRegistry). Every matching detector contributes
#      commands — a Rails+React repo gets both `bundle install` (from
#      the `ruby` plugin) and `npm ci` (from the `javascript` plugin),
#      not just the first hit.
#
# Returns an Array of String commands (possibly empty). Pure;
# no side effects. The Steps::Prepare handler is what actually
# runs them.
class RepoPrepPlan
  CONFIG_FILE = ".syrus.yml".freeze

  Result = Data.define(:commands, :source, :note, :error) do
    def initialize(commands:, source:, note:, error: nil)
      super(commands: commands, source: source, note: note, error: error)
    end

    def self.ok(commands:, source:, note: nil)
      new(commands: commands, source: source, note: note, error: nil)
    end

    def self.error(source:, message:)
      new(commands: [], source: source, note: message, error: message)
    end

    # Auto-detected plans are a *guess* — Syrus inferred the command
    # from a lockfile, the repo never asked for it. Steps::Prepare
    # soft-fails these (warn + hand off to the agent anyway) so a wrong
    # guess can't wedge onboarding. Explicit `.syrus.yml` plans, by
    # contrast, are operator intent and hard-fail. The source string is
    # the discriminator: `from_auto_detect` always prefixes "auto-detect".
    def guessed?
      source.to_s.start_with?("auto-detect")
    end

    def error?
      error.present?
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
      Result.ok(commands: commands, source: ".syrus.yml",
                note: commands.empty? ? "prepare: [] — no commands" : nil)
    when false, nil
      Result.ok(commands: [], source: ".syrus.yml",
                note: "prepare: #{raw.inspect} — opted out")
    else
      Result.error(source: ".syrus.yml",
                   message: "prepare: must be an array of strings (got #{raw.class})")
    end
  rescue SyrusYml::ParseError => e
    Result.error(source: ".syrus.yml", message: e.message)
  end

  def from_auto_detect
    matches = plugin_detector_matches

    if matches.empty?
      Result.ok(commands: [], source: "auto-detect", note: "no recognized signals — skipping")
    else
      commands = matches.flat_map { |_label, cmds| cmds }.uniq
      labels = matches.map(&:first)
      Result.ok(commands: commands, source: "auto-detect (#{labels.join(', ')})", note: nil)
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
end
