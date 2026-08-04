class RepoAgentInsightPlan
  CONFIG_FILE = SyrusYml::CONFIG_FILE

  Result = Data.define(:prepare, :source, :note) do
    def prepare?
      prepare == true
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
    return default(note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return default(note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    return default(note: "no .syrus.yml") unless file

    insight = SyrusYml.new(file.fetch(:content)).parse.agent_insight
    return default(source: ".syrus.yml", note: "no agent_insight configured") unless insight

    Result.new(prepare: insight.prepare, source: ".syrus.yml", note: nil)
  rescue SyrusYml::ParseError => e
    default(source: ".syrus.yml", note: e.message)
  rescue StandardError => e
    Rails.logger.warn("[RepoAgentInsightPlan] defaulting for #{repository.slug}: #{e.class}: #{e.message}")
    default(note: e.message)
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

  def default(source: "none", note:)
    Result.new(prepare: false, source: source, note: note)
  end
end
