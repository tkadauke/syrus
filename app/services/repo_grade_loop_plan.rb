# Resolves whether the repository's `.syrus.yml` configures formatters,
# generated-file checks, or CI graders, so Workflows::Base can decide
# whether to materialize the format/generate/grade retry loop for a
# workflow at all — rather than always creating Steps that just self-skip
# as no-ops when nothing is configured.
#
# Scoped to the initial/retry/pr_comment/chat_feedback "autofix" grade loop
# (see Workflows::Base.grader_retry_loop). Mirrors RepoAdversarialReviewPlan
# / RepoVisualReviewPlan / RepoCoveragePlanReader: the chain is materialized
# before the workflow workspace is cloned, so this resolver reads the
# repository's default-branch config through GitHub. The later
# format/generate/grader_fanout steps still read `.syrus.yml` from the
# clone for the diff-scoped/per-grader detail.
class RepoGradeLoopPlan
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  Result = Data.define(:format_configured, :generate_configured, :graders_configured, :source, :note) do
    def any_configured?
      format_configured || generate_configured || graders_configured
    end
  end

  def self.for_job(job)
    new(repository: job.repository, user: job.user).resolve
  end

  def initialize(repository:, user:, client: nil)
    @repository = repository
    @user = user
    @client = client
  end

  def resolve
    return unconfigured(source: "none", note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return unconfigured(source: "none", note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return unconfigured(source: "none", note: "no .syrus.yml") unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    Result.new(
      format_configured: config.formatters.is_a?(Array) && config.formatters.any?,
      generate_configured: config.generated.is_a?(Array) && config.generated.any?,
      graders_configured: config.grade.present? && config.grade.steps.any?,
      source: ".syrus.yml",
      note: nil
    )
  rescue SyrusYml::ParseError => e
    unconfigured(source: ".syrus.yml", note: e.message)
  rescue StandardError => e
    Rails.logger.warn("[RepoGradeLoopPlan] disabled for #{repository.slug}: #{e.class}: #{e.message}")
    unconfigured(source: "none", note: e.message)
  end

  private

  attr_reader :repository, :user

  def github_client
    return @client if @client

    client = GithubClient.for(repository: repository, user: user)
    client if client.is_a?(GithubClient)
  end

  def credentials_available?
    repository.installation&.active? || user.github_token.present?
  end

  def unconfigured(source:, note:)
    Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: source, note: note)
  end
end
