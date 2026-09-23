# How many commits a PR branch is behind its base. Prefers a
# repository_content_provider's numeric divergence -- git_mirror's already-
# synchronized local bare mirror, or GitHub's compare API -- over
# RepositoryBareClone, which needs its own network fetch on every call.
# Falls back to RepositoryBareClone only when no provider can answer (no
# provider serves the repository, or every one that does is unavailable).
class CommitsBehindCalculator
  def self.call(repository:, user:, head_sha:, base_sha:)
    new(repository: repository, user: user).call(head_sha: head_sha, base_sha: base_sha)
  end

  def initialize(repository:, user:)
    @repository = repository
    @user = user
  end

  # Returns nil when either SHA is blank.
  def call(head_sha:, base_sha:)
    return nil if head_sha.blank? || base_sha.blank?

    from_provider(head_sha: head_sha, base_sha: base_sha) || from_bare_clone(head_sha: head_sha, base_sha: base_sha)
  end

  private

  def from_provider(head_sha:, base_sha:)
    content = RepositoryContent.for(@repository, user: @user)
    content.divergence(base: content.revision(base_sha), head: content.revision(head_sha)).behind
  rescue RepositoryContent::Error => e
    Rails.logger.info("[CommitsBehindCalculator] #{@repository.slug} provider divergence unavailable, falling back to bare clone: #{e.class}: #{e.message}")
    nil
  end

  def from_bare_clone(head_sha:, base_sha:)
    bare_clone = RepositoryBareClone.new(@repository)
    bare_clone.sync!(user: @user)
    bare_clone.commits_behind(head_sha: head_sha, base_sha: base_sha)
  end
end
