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

  # `config` is the parsed SyrusYml::Config, or nil when there is none -- see
  # `outcome` for which kind of none, and `note` for why.
  #
  # `outcome` is the part that matters for safety. It separates "the
  # repository has no .syrus.yml" from "we could not find out":
  #
  #   :loaded       parsed successfully; `config` is set
  #   :absent       the file genuinely does not exist
  #   :invalid      the file exists but did not parse
  #   :unavailable  we could not read it -- no credentials, a rate limit, a
  #                 5xx, a timeout
  #
  # Every non-loaded outcome used to look identical (config: nil), so a
  # rate-limited read at workflow creation was indistinguishable from a repo
  # with no graders, and the workflow was built without a grade loop. Callers
  # that only display config can keep reading `config`; anything that makes a
  # safety decision from it must check `determined?` first.
  #
  # `outcome` defaults from `config` so existing constructions keep their
  # meaning: a Result built with `config: nil` still reads as absent.
  Result = Data.define(:config, :source, :note, :outcome) do
    def initialize(config:, source:, note:, outcome: nil)
      super(config:, source:, note:, outcome: outcome || (config ? :loaded : :absent))
    end

    def loaded? = outcome == :loaded
    def absent? = outcome == :absent

    # True when we positively know what the repository has: a parsed config,
    # or a confirmed absence. False when we could not read it or it did not
    # parse -- the cases where acting on `config: nil` would be a guess.
    def determined? = loaded? || absent?
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
    return unavailable(note: "no GitHub credentials") unless credentials_available?

    client = github_client
    return unavailable(note: "GitHub client unavailable") unless client

    file = client.file_content_at(repository.slug, CONFIG_FILE, repository.default_branch)
    # nil is GitHub answering "no such file" -- the one case that is a real
    # absence rather than a failure to look.
    return Result.new(config: nil, source: "none", note: "no .syrus.yml", outcome: :absent) unless file

    config = SyrusYml.new(file.fetch(:content)).parse
    Result.new(config: config, source: ".syrus.yml", note: nil, outcome: :loaded)
  rescue SyrusYml::ParseError => e
    Result.new(config: nil, source: ".syrus.yml", note: e.message, outcome: :invalid)
  rescue StandardError => e
    Rails.logger.warn("[RepoDefaultBranchSyrusYml] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
    unavailable(note: e.message)
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

  def unavailable(note:)
    Result.new(config: nil, source: "none", note: note, outcome: :unavailable)
  end
end
