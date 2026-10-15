require "uri"

class RepositoryBareCloneRemoteScrubber
  Result = Data.define(:processed, :scrubbed, :removed, :failed, :done)

  def initialize(root: WorkflowWorkspace.data_root.join("clones"), git: GitRunner.new)
    @root = Pathname.new(root)
    @git = git
  end

  def credentialed_remote_count
    credentialed_clone_paths.size
  end

  def scrub_batch(limit:)
    paths = credentialed_clone_paths.first(limit.to_i)
    scrubbed = 0
    removed = 0
    failed = 0

    paths.each do |path|
      action = scrub_path(path)
      scrubbed += 1 if action == :scrubbed
      removed += 1 if action == :removed
    rescue GitRunner::GitError
      failed += 1
    end

    Result.new(
      processed: paths.size,
      scrubbed: scrubbed,
      removed: removed,
      failed: failed,
      done: credentialed_remote_count.zero?
    )
  end

  private

  attr_reader :root, :git

  def credentialed_clone_paths
    return [] unless root.directory?

    root.children
      .select { |path| path.directory? && path.basename.to_s.end_with?(".git") }
      .select { |path| credentialed_origin_url?(origin_url(path)) }
      .sort_by(&:to_s)
  end

  def origin_url(path)
    git.run("config", "--get", "remote.origin.url", chdir: path.to_s).strip
  rescue GitRunner::GitError
    nil
  end

  def credentialed_origin_url?(url)
    return false if url.blank?

    uri = URI.parse(url)
    uri.is_a?(URI::HTTP) && uri.userinfo.present?
  rescue URI::InvalidURIError
    url.match?(%r{\Ahttps?://[^/@]+:[^/@]+@}i)
  end

  def scrub_path(path)
    if (repository = repository_for(path))
      git.run("remote", "set-url", "origin", repository.remote_url, chdir: path.to_s)
      :scrubbed
    else
      git.run("remote", "remove", "origin", chdir: path.to_s)
      :removed
    end
  end

  def repository_for(path)
    id = path.basename.to_s.delete_suffix(".git")
    return nil unless id.match?(/\A\d+\z/)

    Repository.find_by(id: id.to_i)
  end
end
