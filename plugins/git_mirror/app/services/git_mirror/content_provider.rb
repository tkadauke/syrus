module GitMirror
  # The mirror as a repository content replica: asked before the hosting
  # platform, and falling through to it whenever it cannot answer. See
  # Syrus::Plugin::RepositoryContentProvider for the contract.
  class ContentProvider
    include Syrus::Plugin::RepositoryContentProvider

    class << self
      def provider_key = "git_mirror"
      def display_name = "Git Mirror"
      def role = :replica

      # A mirror serves a repository only while the service is up and some
      # upstream can give it credentials to stay in sync. Both checks are
      # local: the service status is what Plugin Runtime last recorded.
      def available_for?(repository)
        repository.present? && repository.vcs == "git" && endpoint.present? && upstream_for?(repository)
      end

      def build(repository:, user:)
        url = endpoint
        url ? new(repository: repository, client: Client.new(endpoint: url)) : nil
      end

      def endpoint
        PluginRuntime::Services.endpoint_for(Configuration::SERVICE_NAME)
      end

      private

      def upstream_for?(repository)
        RepositoryContent.provider_classes.any? do |klass|
          klass != self && klass.role == :upstream && klass.respond_to?(:upstream_source) && klass.available_for?(repository)
        end
      end
    end

    def initialize(repository:, client:)
      @repository = repository
      @client = client
    end

    def resolve(ref, max_age:)
      result = registered { @client.resolve(mirror_id, ref, max_age: max_age) }
      RepositoryContent::Revision.new(id: result.fetch("id"), ref: ref, observed_at: Time.zone.parse(result.fetch("observed_at")))
    end

    def tree(revision_id)
      registered { @client.tree(mirror_id, revision_id) }.map do |entry|
        RepositoryContent::Entry.new(path: entry.fetch("path"), type: entry.fetch("type"), size: entry["size"], content_id: entry["content_id"])
      end
    end

    def read(revision_id, path)
      bytes, content_id = registered { @client.blob(mirror_id, revision_id, path) }
      RepositoryContent::Blob.new(path: path, bytes: bytes, content_id: content_id)
    end

    def changes(base_id, head_id, patch: false)
      registered { @client.changes(mirror_id, base_id, head_id, patch: patch) }.map do |change|
        RepositoryContent::Change.new(
          path: change.fetch("path"),
          status: change.fetch("status"),
          previous_path: change["previous_path"],
          additions: change["additions"],
          deletions: change["deletions"],
          patch: patch ? change["patch"] : nil
        )
      end
    end

    private

    def mirror_id = @repository.id.to_s

    # After the mirror restarts it holds no credentials until the next sync
    # tick. Rather than send every read to the host until then, register this
    # repository on the spot and ask once more. If there is no upstream source
    # to register with, the original Unavailable stands and the chain moves on.
    def registered
      yield
    rescue Client::Unregistered
      source = RepositoryContent.upstream_source_for(@repository)
      raise unless source

      @client.register(mirror_id, source)
      yield
    end
  end
end
