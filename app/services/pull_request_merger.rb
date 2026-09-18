# The one Octokit merge call site every landing path shares.
# `Steps::AutoMerge` wraps this in landing-specific retry/rebase-rejection
# handling; `EmergencyLand::Lander` deliberately does not -- it fails fast
# instead of kicking off a rebase workflow. Both call into this class so the
# actual GitHub API shape (positional repo/PR, commit_title, merge_method)
# lives in exactly one place.
class PullRequestMerger
  DEFAULT_MERGE_METHOD = "rebase".freeze

  def initialize(repository, client:)
    @repository = repository
    @client = client
  end

  def merge(pr_number:, commit_title:, merge_method: DEFAULT_MERGE_METHOD)
    @client.merge_pull_request(
      @repository.slug,
      pr_number,
      commit_title: commit_title,
      merge_method: merge_method
    )
  end
end
