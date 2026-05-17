class PullRequestOpener
  def initialize(repository, client: nil)
    @repository = repository
    @client = client || GithubClient.for(repository: @repository, user: @repository.user)
  end

  # Returns the new PR number.
  def open(branch:, title:, body:, job: nil)
    pr = @client.create_pull_request(
      @repository.slug,
      base: job&.effective_base_branch || @repository.default_branch,
      head: branch,
      title: title,
      body: body
    )
    pr.number
  end
end
