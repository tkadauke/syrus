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
#   2. Auto-detect from the standard package-manager signals
#      (Gemfile, yarn.lock, pnpm-lock.yaml, package-lock.json,
#      package.json). Picks the first hit in priority order so
#      mixed-lockfile repos don't run conflicting installs.
#
# v1 covers Ruby + Node. Python (poetry/uv/pip) deferred until
# we need it.
#
# Returns an Array of String commands (possibly empty). Pure;
# no side effects. The Steps::Prepare handler is what actually
# runs them.
class RepoPrepPlan
  CONFIG_FILE = ".syrus.yml".freeze

  # Auto-detect rules, evaluated in order. First file that exists
  # wins; Syrus runs that command and stops looking. Stops at the
  # first hit so a Rails-with-Node repo doesn't get bundle install
  # AND npm install AND yarn install run in series — the lockfile
  # tells us which package manager the repo standardized on.
  AUTO_DETECT = [
    [ "Gemfile",            "bundle install" ],
    [ "yarn.lock",          "yarn install --frozen-lockfile" ],
    [ "pnpm-lock.yaml",     "pnpm install --frozen-lockfile" ],
    [ "package-lock.json",  "npm ci" ],
    [ "package.json",       "npm install" ]
  ].freeze

  Result = Data.define(:commands, :source, :note)

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
    AUTO_DETECT.each do |file, command|
      return Result.new(commands: [ command ], source: "auto-detect (#{file})",
                        note: nil) if @path.join(file).exist?
    end
    Result.new(commands: [], source: "auto-detect", note: "no recognized signals — skipping")
  end
end
