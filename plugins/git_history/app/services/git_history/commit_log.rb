module GitHistory
  # Walks a repository's local bare clone (RepositoryBareClone) commit-by-
  # commit, newest first, in cursor-paginated pages. Never syncs the clone
  # (that's the job of the background pollers that already maintain it) —
  # a missing clone just means "not available yet", not an error.
  class CommitLog
    FORMAT = "%H%x09%an%x09%ae%x09%cn%x09%ce%x09%aI%x09%s%x00".freeze

    # cursor is always a commit sha echoed back from a previous page (see
    # #fetch below). It is passed as a positional revision argument to `git
    # log`, not through a shell, so there is no shell-injection risk — but an
    # unvalidated value is still a *git argument* injection risk: something
    # like `--output=/some/path` or `--all` would be accepted by `git log`
    # as a flag instead of a revision, letting a caller write arbitrary files
    # or read commits across every ref in the bare clone instead of just the
    # default branch. Restricting cursor to a bare hex string (git's own SHA
    # alphabet) rules out anything flag-shaped or option-shaped by
    # construction.
    CURSOR_PATTERN = /\A[0-9a-fA-F]{4,40}\z/.freeze

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
      return Page.new(entries: [], has_more: false) if cursor.present? && !valid_cursor?(cursor)

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

    def valid_cursor?(cursor)
      CURSOR_PATTERN.match?(cursor)
    end

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
