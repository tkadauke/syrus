module GitMirror
  # `:workspace_git_transport` provider: hands WorkflowWorkspace/ChatWorkspace
  # a clone/fetch URL straight into the mirror's own smart-HTTP git routes
  # (see the container's internal/server package) instead of the hosting
  # platform.
  #
  # This is an adapter over ContentProvider, not a sibling that repeats its
  # machinery: availability, endpoint resolution, and reactive registration
  # (a restarted mirror holds no credentials until the next sync tick) all
  # delegate to a ContentProvider instance bound to the same repository, so
  # there is exactly one place that knows how to register a repository with
  # the mirror or decide whether it's serving it right now. Only the git URL
  # itself -- ContentProvider's JSON client never needs one -- is this
  # class's own concern.
  class WorkspaceGitTransport
    include Syrus::Plugin::WorkspaceGitTransport

    class << self
      def available_for?(repository)
        ContentProvider.available_for?(repository)
      end

      def build(repository:, user:)
        provider = ContentProvider.build(repository: repository, user: user)
        provider && new(provider: provider)
      end
    end

    def initialize(provider:)
      @provider = provider
    end

    # Bare host + path; git appends /info/refs and /git-upload-pack itself.
    def url
      "#{ContentProvider.endpoint}/v1/repositories/#{@provider.mirror_id}"
    end

    # The bearer token travels as an `http.extraHeader`, never in the URL: it
    # must not land in `.git/config`, a `git remote -v` listing, or a git
    # error message that ends up in JobLog.
    def env
      {
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "http.extraHeader",
        "GIT_CONFIG_VALUE_0" => "Authorization: Bearer #{Configuration.token}"
      }
    end

    # Best-effort: make sure the mirror actually knows about this repository.
    # Delegates to ContentProvider#register! -- the same reactive
    # registration it runs on its own JSON reads -- except a missing
    # registration surfaces here as an ordinary git transport failure (the
    # mirror never having heard of the id), not a typed error to rescue, so
    # the caller just retries once after calling this.
    def register!
      @provider.register!
    end
  end
end
