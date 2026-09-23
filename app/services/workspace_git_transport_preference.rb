# Shared by WorkflowWorkspace and ChatWorkspace: try a repository's
# registered `:workspace_git_transport` (e.g. Git Mirror) for a clone/fetch
# before falling back to the hosting platform.
module WorkspaceGitTransportPreference
  # Attempts a clone/fetch entirely through the repository's registered
  # workspace_git_transport, retrying once after explicit re-registration --
  # the common reason a transport doesn't yet have a repository is that it
  # hasn't been told about it since it last restarted. `op` receives
  # `(url, env)` and performs the actual `GitRunner#run` call.
  #
  # Returns true when `op` succeeded and (when `verify_sha` is given) the
  # wanted commit actually ended up on disk, checked via the includer's own
  # `#git_object_present?(sha)`. Returns false when no transport is
  # available, or every attempt either raised a GitRunner::GitError or
  # landed on a stale commit -- the caller should fall back to the hosting
  # platform exactly as if this method had never been called; nothing here
  # ever raises for a transport-side failure.
  def try_mirror_transport(repository:, user:, verify_sha: nil, &op)
    transport = WorkspaceGitTransports.for(repository, user: user)
    return false unless transport

    [ false, true ].each do |register_first|
      begin
        transport.register! if register_first
        op.call(transport.url, transport.env)
        return true if verify_sha.blank? || git_object_present?(verify_sha)
      rescue GitRunner::GitError
        nil
      end
    end

    false
  end
end
