require "digest"

module ReviewEvidence::CanonicalDiff
  CAPTURE_LIMIT = 100.megabytes

  module_function

  def snapshot(workspace_path:, base_sha:)
    head_sha = git!(workspace_path, "rev-parse", "HEAD").strip
    diff = git!(workspace_path, "diff", "--no-ext-diff", "--binary", "#{base_sha}...#{head_sha}")
    { head_sha: head_sha, sha256: Digest::SHA256.hexdigest(diff) }
  end

  def resolve(workspace_path:, ref:)
    git!(workspace_path, "rev-parse", "--verify", "#{ref}^{commit}").strip
  end

  def git!(workspace_path, *arguments)
    capture = GitRunner.new.capture(*arguments, chdir: workspace_path.to_s, limit: CAPTURE_LIMIT)
    if capture.stdout_truncated || capture.stderr_truncated
      raise "git #{arguments.first} output exceeded #{CAPTURE_LIMIT} bytes"
    end
    return capture.stdout if capture.success?

    raise GitRunner::GitError.new(arguments, capture.result.exit_status || -1,
                                  "#{capture.stdout}#{capture.stderr}")
  end
end
