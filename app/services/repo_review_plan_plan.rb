# Resolves whether the repository's `.syrus.yml` opts into the review_plan
# step, so Workflows::Base can decide whether to materialize a review_plan
# Step at all -- rather than always creating one that just skips itself as
# a no-op when unconfigured.
#
# Mirrors RepoAdversarialReviewPlan/RepoVisualReviewPlan: the
# initial_pr_finish_steps chain is materialized before the workflow
# workspace is cloned, so this resolver reads the repository's
# default-branch config through GitHub. Unlike those two, there is no
# instance-wide fallback -- review_plan is opt-in per `.syrus.yml` only,
# same as Steps::ReviewPlan's own (still-retained) runtime check.
class RepoReviewPlanPlan
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  Result = Data.define(:enabled, :source, :note) do
    def enabled?
      enabled
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
    return disabled(source: "none", note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return disabled(source: "none", note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return disabled(source: "none", note: "no .syrus.yml") unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    Result.new(enabled: config.review_plan, source: ".syrus.yml", note: nil)
  rescue SyrusYml::ParseError => e
    disabled(source: ".syrus.yml", note: e.message)
  rescue StandardError => e
    Rails.logger.warn("[RepoReviewPlanPlan] disabled for #{repository.slug}: #{e.class}: #{e.message}")
    disabled(source: "none", note: e.message)
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

  def disabled(source:, note:)
    Result.new(enabled: false, source: source, note: note)
  end
end
