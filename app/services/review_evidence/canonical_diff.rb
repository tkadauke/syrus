require "digest"
require "open3"

module ReviewEvidence::CanonicalDiff
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
    output, error, status = Open3.capture3("git", "-C", workspace_path.to_s, *arguments)
    return output if status.success?

    raise "git #{arguments.first} failed: #{error.to_s.strip.presence || output.to_s.strip}"
  end
end
