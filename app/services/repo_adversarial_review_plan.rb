# Resolves the optional adversarial review loop configured in `.syrus.yml`.
#
# The Initial workflow chain is materialized before the workflow workspace is
# cloned, so this resolver reads the repository's default-branch config through
# GitHub. The later prepare/grade steps still read `.syrus.yml` from the clone.
class RepoAdversarialReviewPlan
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  Result = Data.define(:rounds, :source, :note) do
    def enabled?
      rounds.to_i.positive?
    end
  end

  def self.for_job(job)
    new(repository: job.repository, user: job.user).resolve
  end

  def initialize(repository:, user:)
    @repository = repository
    @user = user
  end

  def resolve
    file = GithubClient
             .for(repository: repository, user: user)
             .file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return disabled(source: "none", note: "no .syrus.yml") unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    review = config.adversarial_review
    return disabled(source: ".syrus.yml", note: "no adversarial_review configured") unless review

    Result.new(rounds: review.rounds, source: ".syrus.yml", note: nil)
  rescue SyrusYml::ParseError => e
    disabled(source: ".syrus.yml", note: e.message)
  rescue ArgumentError, Octokit::Error, Faraday::Error => e
    Rails.logger.warn("[RepoAdversarialReviewPlan] disabled for #{repository.slug}: #{e.class}: #{e.message}")
    disabled(source: "none", note: e.message)
  end

  private

  attr_reader :repository, :user

  def disabled(source:, note:)
    Result.new(rounds: 0, source: source, note: note)
  end
end
