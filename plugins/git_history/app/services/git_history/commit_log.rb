module GitHistory
  # Walks a repository's local bare clone (RepositoryBareClone) commit-by-
  # commit, newest first, in cursor-paginated pages. Never syncs the clone
  # (that's the job of the background pollers that already maintain it) —
  # a missing clone just means "not available yet", not an error.
  class CommitLog
    FORMAT = "%H%x09%an%x09%ae%x09%cn%x09%ce%x09%aI%x09%s%x00".freeze

    Page = Struct.new(:entries, :has_more, keyword_init: true)

    def initialize(repository:, git: nil)
      @repository = repository
      @git = git || GitRunner.new
    end

    def available?
      bare_clone_path.exist?
    end

    # cursor is the sha of the last commit returned by the previous page
    # (nil for the first page, which starts at the default branch tip).
    # Walking is done by re-pointing `git log` AT the cursor commit and
    # skipping it (already returned), rather than a numeric --skip offset,
    # so pagination stays stable even if the branch advances between pages.
    def fetch(cursor:, limit:)
      return Page.new(entries: [], has_more: false) unless available?

      args = [ "log", cursor.presence || @repository.default_branch ]
      args << "--skip=1" if cursor.present?
      args += [ "--max-count=#{limit + 1}", "--pretty=format:#{FORMAT}" ]

      output = @git.run(*args, chdir: bare_clone_path.to_s)
      entries = parse(output)
      Page.new(entries: entries.first(limit), has_more: entries.size > limit)
    rescue GitRunner::GitError
      Page.new(entries: [], has_more: false)
    end

    private

    def bare_clone_path
      @bare_clone_path ||= RepositoryBareClone.path_for(@repository)
    end

    def parse(output)
      output.split("\x00").map(&:strip).reject(&:empty?).map do |record|
        sha, author_name, author_email, committer_name, committer_email, authored_at, subject = record.split("\t", 7)
        {
          sha: sha,
          author_name: author_name,
          author_email: author_email,
          committer_name: committer_name,
          committer_email: committer_email,
          authored_at: authored_at,
          subject: subject.to_s
        }
      end
    end
  end
end
