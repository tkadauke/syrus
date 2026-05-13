require "yaml"
require "set"

# Resolves Syrus-native CI graders declared in `.syrus.yml`.
# Supports both:
#
#   grade:
#     steps:
#       - name: tests
#         run: bin/rspec
#
# and the shorthand:
#
#   grade:
#     - name: tests
#       run: bin/rspec
class RepoGradePlan
  CONFIG_FILE = ".syrus.yml".freeze
  DEFAULT_TIMEOUT_MINUTES = 15
  MAX_TIMEOUT_MINUTES = 30
  NAME_PATTERN = /\A[a-zA-Z0-9-]+\z/

  Grader = Data.define(:name, :command, :required, :timeout_minutes)
  Result = Data.define(:graders, :source, :note)

  def self.for(workspace_path)
    new(workspace_path).resolve
  end

  def initialize(workspace_path)
    @path = Pathname.new(workspace_path)
  end

  def resolve
    return Result.new(graders: [], source: "none", note: "no .syrus.yml") unless config_present?

    yaml = YAML.safe_load(@path.join(CONFIG_FILE).read) || {}
    raw = yaml["grade"]
    entries = raw.is_a?(Hash) ? raw["steps"] : raw

    unless entries.is_a?(Array)
      return Result.new(graders: [], source: ".syrus.yml", note: "no graders configured")
    end

    seen = Set.new
    graders = entries.filter_map { |entry| parse_entry(entry, seen) }
    note = graders.empty? ? "no valid graders configured" : nil
    Result.new(graders: graders, source: ".syrus.yml", note: note)
  rescue Psych::SyntaxError => e
    Result.new(graders: [], source: ".syrus.yml", note: "YAML parse error: #{e.message}")
  end

  private

  def config_present?
    @path.join(CONFIG_FILE).exist?
  end

  def parse_entry(entry, seen)
    return nil unless entry.is_a?(Hash)

    name = entry["name"].to_s.strip
    command = entry["run"].to_s.strip
    return nil if name.empty? || command.empty?
    return nil unless name.match?(NAME_PATTERN)
    return nil if seen.include?(name)

    seen << name

    Grader.new(
      name: name,
      command: command,
      required: entry.key?("required") ? !!entry["required"] : true,
      timeout_minutes: timeout_minutes(entry["timeout_minutes"])
    )
  end

  def timeout_minutes(value)
    minutes = value.to_i
    minutes = DEFAULT_TIMEOUT_MINUTES if minutes <= 0
    [ minutes, MAX_TIMEOUT_MINUTES ].min
  end
end
