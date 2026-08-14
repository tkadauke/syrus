# Resolves the optional visual_review loop configured in `.syrus.yml`,
# falling back to the instance-wide AppSetting default when the repository
# hasn't configured (or couldn't fetch) a visual_review block.
#
# Mirrors RepoAdversarialReviewPlan: the Initial workflow chain is
# materialized before the workflow workspace is cloned, so this resolver
# reads the repository's default-branch config through GitHub. The later
# visual_review step still reads `.syrus.yml` from the clone (for
# when_files_changed and seed_notes, which depend on the actual diff).
class RepoVisualReviewPlan
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  Result = Data.define(:enabled, :rounds, :source, :note) do
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
    return instance_default(source: "none", note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return instance_default(source: "none", note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return instance_default(source: "none", note: "no .syrus.yml") unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    review = config.visual_review
    return instance_default(source: ".syrus.yml", note: "no visual_review configured") unless review

    Result.new(enabled: review.enabled, rounds: review.rounds, source: ".syrus.yml", note: nil)
  rescue SyrusYml::ParseError => e
    instance_default(source: ".syrus.yml", note: e.message)
  rescue StandardError => e
    Rails.logger.warn("[RepoVisualReviewPlan] falling back to instance default for #{repository.slug}: #{e.class}: #{e.message}")
    instance_default(source: "none", note: e.message)
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

  def instance_default(source:, note:)
    Result.new(enabled: AppSetting.visual_review_enabled?, rounds: SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS, source: source, note: note)
  end
end
