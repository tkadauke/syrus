class RepoReconciliationPlan
  DEFAULT_MODE = "pr"

  Result = Data.define(:mode, :source, :note)

  # Returns the legacy standalone reconciliation mode for the given Epic.
  # New Epics reconcile during merge-train landing; this remains for
  # historical reconciliation Jobs and compatibility with persisted settings.
  # Precedence: Epic column → .syrus.yml → default ("pr").
  def self.for_epic(epic)
    if epic.reconciliation_mode.present?
      return Result.new(mode: epic.reconciliation_mode, source: "epic", note: nil)
    end

    yml_mode = load_yml_mode(epic)
    if yml_mode.present?
      return Result.new(mode: yml_mode, source: "syrus_yml", note: nil)
    end

    Result.new(mode: DEFAULT_MODE, source: "default", note: nil)
  end

  def self.load_yml_mode(epic)
    client = GithubClient.for(repository: epic.repository, user: epic.user)
    return nil unless client.is_a?(GithubClient)

    file = client.file_content_at(
      epic.repository.slug,
      SyrusYml::CONFIG_FILE,
      epic.repository.default_branch
    )
    return nil unless file

    raw = YAML.safe_load(file.fetch(:content)) || {}
    return nil unless raw.is_a?(Hash)

    SyrusYml.new(file.fetch(:content)).parse.reconciliation_mode
  rescue SyrusYml::ParseError, Psych::SyntaxError, StandardError => e
    Rails.logger.warn("[RepoReconciliationPlan] reconciliation_mode unresolvable for #{epic.repository.slug}: #{e.message}")
    nil
  end
  private_class_method :load_yml_mode
end
