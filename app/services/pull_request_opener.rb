class PullRequestOpener
  # repository     — where the PR is opened (target / upstream for cross-fork)
  # head_repository — where the branch lives (fork repo); defaults to repository
  def initialize(repository, client: nil, head_repository: nil)
    @repository = repository
    @head_repository = head_repository || repository
    @client = client || GithubClient.for(repository: @repository, user: @repository.user)
  end

  # Returns the new or already-open PR number.
  def open(branch:, title:, body:, job: nil, base: nil)
    base_branch = base.presence || job&.effective_base_branch || @repository.default_branch
    head = head_ref(branch)

    if (existing = existing_open_pull_request(base: base_branch, head: head))
      return existing.number
    end

    pr = @client.create_pull_request(
      @repository.slug,
      base: base_branch,
      head: head,
      title: title,
      body: body
    )
    pr.number
  rescue Octokit::Error => e
    if pull_request_already_exists?(e) && (existing = existing_open_pull_request(base: base_branch, head: head))
      return existing.number
    end

    if transient_github_error?(e) && (existing = existing_open_pull_request(base: base_branch, head: head))
      return existing.number
    end

    raise
  end

  private

  def head_ref(branch)
    "#{@head_repository.owner}:#{branch}"
  end

  def existing_open_pull_request(base:, head:)
    @client.open_pull_request_for_head(@repository.slug, base: base, head: head)
  end

  def pull_request_already_exists?(error)
    error.respond_to?(:response_status) &&
      error.response_status.to_i == 422 &&
      error.message.to_s.match?(/pull request already exists/i)
  end

  def transient_github_error?(error)
    error.respond_to?(:response_status) && error.response_status.to_i >= 500
  end
end
