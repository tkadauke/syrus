# Shared by WorkflowWorkspace and ChatWorkspace: clone/fetch through a
# repository's registered `:workspace_git_transport` (e.g. Git Mirror)
# before falling back to the hosting platform.
#
# `clone_via_transport!`/`fetch_via_transport!` are the entry points callers
# should reach for -- they own the operational choreography (clearing a
# partial destination, trying the mirror, falling back to `fallback` when
# it's unavailable or fails) so a workspace class only has to say what it
# wants ("clone this branch", "fetch this refspec") and how to reach GitHub
# when the mirror can't help. `try_mirror_transport` is the shared primitive
# both build on; it stays public because it is independently unit-tested
# (see workspace_git_transport_preference_spec.rb) and is the seam a future
# caller would use if its GitHub-side fallback ever doesn't fit a single
# `fallback` block.
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
      rescue GitRunner::GitError, RepositoryContent::Error
        nil
      end
    end

    false
  end

  # Clones `dest` from the repository's preferred git transport, falling
  # back to the hosting platform when the mirror is unavailable or fails.
  # Expresses the intent every caller has ("clone this branch") once,
  # instead of each hand-rolling the mirror attempt plus GitHub fallback:
  # `dest` is cleared before every attempt, mirror or fallback, since a
  # failed clone can leave a non-empty destination behind that the next
  # attempt would otherwise refuse to write into. `clone_args` are the git
  # argv shared by both attempts (e.g. `--branch main --no-tags`), placed
  # between `clone` and the url/destination. `fallback` performs the actual
  # GitHub clone -- it only runs when the mirror is unavailable or every
  # mirror attempt failed.
  def clone_via_transport!(repository:, user:, dest:, clone_args:, env: {}, &fallback)
    cloned = try_mirror_transport(repository: repository, user: user) do |url, mirror_env|
      FileUtils.rm_rf(dest.to_s) if dest.exist?
      @git.run("clone", *clone_args, url, dest.to_s, env: env.merge(mirror_env))
    end
    return if cloned

    FileUtils.rm_rf(dest.to_s) if dest.exist?
    fallback.call
  end

  # Fetches `refspec` through the repository's preferred git transport,
  # verifying `verify_sha` actually landed on disk (a mirror whose
  # background sync trails real time must never yield a stale checkout)
  # before trusting it, and otherwise falling back via `fallback` -- which
  # only runs when the mirror is unavailable, stale, or every attempt
  # failed.
  def fetch_via_transport!(repository:, user:, refspec:, chdir:, verify_sha: nil, env: {}, &fallback)
    fetched = try_mirror_transport(repository: repository, user: user, verify_sha: verify_sha) do |url, mirror_env|
      @git.run("fetch", url, refspec, chdir: chdir, env: env.merge(mirror_env))
    end
    return if fetched

    fallback.call
  end
end
