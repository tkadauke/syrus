class PullRequestOpener
  # repository     — where the PR is opened (target / upstream for cross-fork)
  # head_repository — where the branch lives (fork repo); defaults to repository
  def initialize(repository, client: nil, head_repository: nil)
    @repository = repository
    @head_repository = head_repository || repository
    @client = client || GithubClient.for(repository: @repository, user: @repository.user)
  end

  # Returns the new PR number.
  def open(branch:, title:, body:, job: nil)
    pr = @client.create_pull_request(
      @repository.slug,
      base: job&.effective_base_branch || @repository.default_branch,
      head: head_ref(branch),
      title: title,
      body: body
    )
    pr.number
  end

  private

  def head_ref(branch)
    "#{@head_repository.owner}:#{branch}"
  end
end
