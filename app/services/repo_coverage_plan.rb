# Resolves coverage configuration from `.syrus.yml`, parallel to RepoGradePlan.
# Returns nil when no coverage configuration is present or when .syrus.yml is
# absent — callers (Steps::CoverageAnalyze) treat nil as "no coverage step needed."
class RepoCoveragePlan
  def self.for(workspace_path)
    new(workspace_path).resolve
  end

  def initialize(workspace_path)
    @path = Pathname.new(workspace_path)
  end

  def resolve
    return nil unless @path.join(SyrusYml::CONFIG_FILE).exist?

    SyrusYml.load_repo(@path).coverage
  rescue SyrusYml::ParseError => e
    Rails.logger.warn("[RepoCoveragePlan] .syrus.yml parse error: #{e.message}")
    nil
  end
end
