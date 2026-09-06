# Shared loader for the repository's default-branch `.syrus.yml`, fetched
# through GitHub at workflow-instantiation time (before the workflow
# workspace is cloned). Centralizes the credentials check, GithubClient
# construction, `file_content_at` call, and SyrusYml parse that
# RepoAdversarialReviewPlan, RepoVisualReviewPlan, RepoGradeLoopPlan,
# RepoReviewPlanPlan, and RepoCoveragePlanReader each used to duplicate --
# each doing its own independent GitHub round-trip for the identical file at
# the identical ref. Workflows::Base resolves this once per workflow
# instantiation and threads the Result through each Repo*Plan.from_syrus_yml
# adapter instead of letting every helper call its own Repo*Plan.for_job.
class RepoDefaultBranchSyrusYml
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  # `config` is the parsed SyrusYml::Config, or nil when unavailable -- see
  # `source`/`note` for why (no credentials, no client, no file, or a parse
  # error).
  Result = Data.define(:config, :source, :note)

  def self.for_job(job)
    new(repository: job.repository, user: job.user).resolve
  end

  def initialize(repository:, user:, client: nil)
    @repository = repository
    @user = user
    @client = client
  end

  def resolve
    return unavailable(source: "none", note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return unavailable(source: "none", note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return unavailable(source: "none", note: "no .syrus.yml") unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    Result.new(config: config, source: ".syrus.yml", note: nil)
  rescue SyrusYml::ParseError => e
    unavailable(source: ".syrus.yml", note: e.message)
  rescue StandardError => e
    Rails.logger.warn("[RepoDefaultBranchSyrusYml] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
    unavailable(source: "none", note: e.message)
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

  def unavailable(source:, note:)
    Result.new(config: nil, source: source, note: note)
  end
end
