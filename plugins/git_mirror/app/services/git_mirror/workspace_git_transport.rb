module GitMirror
  # `:workspace_git_transport` provider: hands WorkflowWorkspace/ChatWorkspace
  # a clone/fetch URL straight into the mirror's own smart-HTTP git routes
  # (see the container's internal/server package) instead of the hosting
  # platform. Same replica-first, fall-through-on-failure posture as
  # ContentProvider, and the same availability check -- a mirror serves a
  # repository only while the service is up and some upstream can hand it
  # credentials.
  class WorkspaceGitTransport
    include Syrus::Plugin::WorkspaceGitTransport

    class << self
      def available_for?(repository)
        ContentProvider.available_for?(repository)
      end

      def build(repository:, user:)
        url = ContentProvider.endpoint
        url ? new(repository: repository, user: user, endpoint: url) : nil
      end
    end

    def initialize(repository:, user:, endpoint:)
      @repository = repository
      @user = user
      @endpoint = endpoint
    end

    # Bare host + path; git appends /info/refs and /git-upload-pack itself.
    def url
      "#{@endpoint}/v1/repositories/#{mirror_id}"
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
    # Mirrors ContentProvider#registered's reactive registration, except a
    # missing registration surfaces here as an ordinary git transport failure
    # (the mirror never having heard of the id), not a typed error to
    # rescue -- the caller just retries once after calling this.
    def register!
      source = RepositoryContent.upstream_source_for(@repository)
      return unless source

      client.register(mirror_id, source)
    end

    private

    def client
      @client ||= Client.new(endpoint: @endpoint)
    end

    def mirror_id = @repository.id.to_s
  end
end
