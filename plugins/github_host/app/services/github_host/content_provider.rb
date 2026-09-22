module GithubHost
  # Repository content straight from the GitHub API: the upstream every
  # GitHub repository can fall back to. See
  # Syrus::Plugin::RepositoryContentProvider for the contract.
  #
  # GitHub's answers are translated into the contract's error vocabulary so
  # the chain knows what to do next: a missing file is NotFound (final), an
  # unknown ref or commit is UnknownRevision, and everything that is really
  # "we could not ask" -- rate limits, 5xx, auth, timeouts -- is Unavailable.
  class ContentProvider
    include Syrus::Plugin::RepositoryContentProvider

    GIT_SHA = /\A\h{40}\z/
    SYMLINK_MODE = "120000".freeze
    GITHUB_COMPARE_FILE_LIMIT = 300

    UNAVAILABLE_ERRORS = [
      Octokit::TooManyRequests,
      Octokit::Unauthorized,
      Octokit::Forbidden,
      Octokit::ServerError,
      Octokit::Error,
      Faraday::Error,
      Timeout::Error,
      SocketError,
      SystemCallError
    ].freeze

    STATUS_FOR = {
      "added" => "added",
      "copied" => "added",
      "modified" => "modified",
      "changed" => "modified",
      "removed" => "deleted",
      "renamed" => "renamed"
    }.freeze

    class << self
      def provider_key = "github"
      def display_name = "GitHub"
      def role = :upstream

      # Every git repository Syrus knows is a GitHub repository today; when
      # other hosts arrive this will read the repository's host.
      def available_for?(repository)
        repository.present? && repository.vcs == "git" && repository.slug.to_s.include?("/")
      end

      def build(repository:, user:)
        return nil unless credentials?(repository, user)

        new(repository: repository, user: user)
      end

      private

      def credentials?(repository, user)
        GithubClient.active_installation_for(repository: repository, user: user).present? ||
          (user || repository.user)&.github_token.present?
      end
    end

    def initialize(repository:, user:, client: nil)
      @repository = repository
      @user = user
      @client = client
    end

    # A 40-hex ref is already a commit SHA -- immutable, so no round-trip.
    # GitHub is the authority for its own refs, so any max_age is satisfied.
    def resolve(ref, max_age:)
      return RepositoryContent::Revision.new(id: ref.downcase, ref: ref, observed_at: Time.current) if ref.match?(GIT_SHA)

      sha = translate(unknown_revision: "unknown ref #{ref}") { client.commit_sha_for(slug, ref) }
      RepositoryContent::Revision.new(id: sha, ref: ref, observed_at: Time.current)
    end

    def tree(revision_id)
      result = translate(unknown_revision: "unknown revision #{revision_id}") { client.commit_tree_entries(slug, revision_id) }
      # GitHub stops listing around 100k entries. A partial tree would make
      # glob searches silently miss files, so say we cannot answer instead.
      raise RepositoryContent::Unsupported, "GitHub truncated the tree of #{slug}@#{revision_id}" if result[:truncated]

      result[:entries].filter_map { |item| entry_for(item) }
    end

    def read(revision_id, path)
      file = translate(unknown_revision: "unknown revision #{revision_id}") { client.file_bytes_at(slug, path, revision_id) }
      raise RepositoryContent::NotFound, "#{path} not found in #{slug}@#{revision_id}" unless file

      RepositoryContent::Blob.new(path: path, bytes: file[:bytes], size: file[:size], content_id: file[:sha])
    end

    def changes(base_id, head_id, patch: false)
      result = translate(unknown_revision: "unknown revision #{base_id}...#{head_id}") { client.compare_file_changes(slug, base_id, head_id) }
      # GitHub lists at most 300 files per comparison. Returning the first
      # 300 as if they were all would be a quiet lie.
      if result[:truncated]
        raise RepositoryContent::Unsupported, "GitHub lists at most #{GITHUB_COMPARE_FILE_LIMIT} changed files"
      end

      result[:files].map do |file|
        RepositoryContent::Change.new(
          path: file[:path],
          status: STATUS_FOR.fetch(file[:status], "modified"),
          previous_path: file[:status] == "renamed" ? file[:previous_path] : nil,
          patch: patch ? file[:patch] : nil,
          additions: file[:additions],
          deletions: file[:deletions]
        )
      end
    end

    private

    attr_reader :repository, :user

    def slug = repository.slug

    # Built on first use rather than in .build: minting an installation token
    # is a network call, and its failure is an outage (Unavailable), not a
    # reason to pretend the provider does not exist.
    def client
      @client ||= GithubClient.for(repository: repository, user: user)
    end

    def translate(unknown_revision:)
      yield
    rescue Octokit::NotFound, Octokit::UnprocessableEntity
      raise RepositoryContent::UnknownRevision, unknown_revision
    rescue *UNAVAILABLE_ERRORS, ArgumentError => e
      raise RepositoryContent::Unavailable, "GitHub: #{e.class}: #{e.message}"
    end

    def entry_for(item)
      case item[:type]
      when "blob"
        type = item[:mode] == SYMLINK_MODE ? "symlink" : "file"
        RepositoryContent::Entry.new(path: item[:path], type: type, size: item[:size], content_id: item[:sha])
      when "commit"
        RepositoryContent::Entry.new(path: item[:path], type: "submodule", content_id: item[:sha])
      end
    end
  end
end
