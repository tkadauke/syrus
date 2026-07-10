# Resolves the optional coverage plan configured in `.syrus.yml`.
#
# Reads the repository's default-branch config through GitHub at
# workflow instantiation time (before the workspace is cloned).
# Returns the RepoCoveragePlan when coverage is configured, nil otherwise.
class RepoCoveragePlanReader
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  def self.for_job(job)
    new(repository: job.repository, user: job.user).resolve
  end

  def initialize(repository:, user:, client: nil)
    @repository = repository
    @user = user
    @client = client
  end

  def resolve
    return nil unless credentials_available?

    client = github_client
    return nil unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return nil unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    config.coverage
  rescue SyrusYml::ParseError => e
    Rails.logger.warn("[RepoCoveragePlanReader] coverage disabled for #{repository.slug}: #{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.warn("[RepoCoveragePlanReader] coverage disabled for #{repository.slug}: #{e.class}: #{e.message}")
    nil
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
end
