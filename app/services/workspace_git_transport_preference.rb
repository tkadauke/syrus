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
  # Returns true when `op` succeeded and either the optional `verify` callback
  # accepts the fetched refs or (when `verify_sha` is given) the wanted commit
  # actually ended up on disk, checked via the includer's own
  # `#git_object_present?(sha)`. Returns false when no transport is
  # available, or every attempt either raised a GitRunner::GitError or
  # landed on a stale commit -- the caller should fall back to the hosting
  # platform exactly as if this method had never been called; nothing here
  # ever raises for a transport-side failure.
  def try_mirror_transport(repository:, user:, verify_sha: nil, verify: nil, &op)
    transport = WorkspaceGitTransports.for(repository, user: user)
    return false unless transport

    [ false, true ].each do |register_first|
      begin
        transport.register! if register_first
        op.call(transport.url, transport.env)
        verified = verify ? verify.call : (verify_sha.blank? || git_object_present?(verify_sha))
        return true if verified
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

    clone_from_hosting_platform!(dest, &fallback)
  end

  # The hosting-platform clone is the last resort, so a dropped connection
  # here used to fail the whole step. Under a flaky uplink GitHub resets large
  # HTTP/2 clones mid-pack ("HTTP/2 stream was not closed cleanly", "early
  # EOF"); a landing's push step that had to re-clone a lost workspace failed
  # that way three times in a row and threw away a fully graded landing.
  # Retry transient transport failures in place, and from the second attempt
  # on ask git for HTTP/1.1, which does not multiplex the pack onto a stream
  # the server can cancel. The fallback receives env to merge into its git
  # call; a fallback that ignores it still gets the plain retries.
  HOSTING_PLATFORM_CLONE_RETRY_DELAYS = [ 5, 20 ].freeze
  HTTP1_GIT_ENV = {
    "GIT_CONFIG_COUNT" => "1",
    "GIT_CONFIG_KEY_0" => "http.version",
    "GIT_CONFIG_VALUE_0" => "HTTP/1.1"
  }.freeze

  def clone_from_hosting_platform!(dest, &fallback)
    attempt = 0
    begin
      FileUtils.rm_rf(dest.to_s) if dest.exist?
      fallback.call(attempt.zero? ? {} : HTTP1_GIT_ENV)
    rescue GitRunner::GitError => e
      delay = HOSTING_PLATFORM_CLONE_RETRY_DELAYS[attempt]
      raise unless delay && GitTransportErrors.transient?(e.message)

      attempt += 1
      Rails.logger.warn("[WorkspaceGitTransportPreference] transient clone failure, retrying (#{attempt}/#{HOSTING_PLATFORM_CLONE_RETRY_DELAYS.size}) over HTTP/1.1: #{e.message.lines.last.to_s.strip}")
      transport_retry_sleep(delay)
      retry
    end
  end

  def transport_retry_sleep(seconds)
    sleep(seconds)
  end

  # Fetches `refspec` through the repository's preferred git transport,
  # verifying `verify_sha` actually landed on disk (a mirror whose
  # background sync trails real time must never yield a stale checkout)
  # before trusting it, and otherwise falling back via `fallback` -- which
  # only runs when the mirror is unavailable, stale, or every attempt
  # failed.
  def fetch_via_transport!(repository:, user:, refspec:, chdir:, verify_sha: nil, verify: nil, env: {}, fetch_args: [], &fallback)
    fetched = try_mirror_transport(repository: repository, user: user, verify_sha: verify_sha, verify: verify) do |url, mirror_env|
      @git.run("fetch", *fetch_args, url, refspec, chdir: chdir, env: env.merge(mirror_env))
    end
    return if fetched

    fallback.call
  end
end
