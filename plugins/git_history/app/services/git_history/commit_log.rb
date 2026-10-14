module GitHistory
  # Walks a repository's local bare clone (RepositoryBareClone) commit-by-
  # commit, newest first, in cursor-paginated pages. Never syncs the clone
  # (that's the job of the background pollers that already maintain it) —
  # a missing clone just means "not available yet", not an error.
  class CommitLog
    FORMAT = "%H%x09%an%x09%ae%x09%cn%x09%ce%x09%aI%x09%s%x00".freeze

    # cursor is an opaque value echoed back from a previous page (see #fetch
    # below). It is passed as a positional revision argument plus a numeric
    # offset to `git log`, not through a shell, so there is no shell-injection
    # risk — but an unvalidated value is still a *git argument* injection
    # risk: something like `--output=/some/path` or `--all` would be accepted
    # by `git log` as a flag instead of a revision, letting a caller write
    # arbitrary files or read commits across every ref in the bare clone
    # instead of just the default branch. Restricting the revision part to a
    # bare hex string (git's own SHA alphabet) and the offset to digits rules
    # out anything flag-shaped or option-shaped by construction.
    CURSOR_PATTERN = /\A(?<tip>[0-9a-fA-F]{4,40})(?::(?<offset>\d+))?\z/.freeze

    Page = Struct.new(:entries, :has_more, :next_cursor, keyword_init: true)

    def initialize(repository:, git: nil)
      @repository = repository
      @git = git || GitRunner.new
    end

    def available?
      bare_clone_path.exist?
    end

    # cursor pins the first page's tip sha plus the count of commits already
    # returned (`<tip_sha>:<offset>`). That keeps later pages walking the same
    # revision graph as page one, including commits reachable only through the
    # other parent of a merge commit. Bare sha cursors from older clients are
    # still accepted as the legacy "start at this commit and skip one" shape.
    def fetch(cursor:, limit:)
      return Page.new(entries: [], has_more: false) unless available?
      pagination = parse_cursor(cursor)
      return Page.new(entries: [], has_more: false) if cursor.present? && !pagination

      args = [ "log", pagination&.fetch(:tip) || @repository.default_branch ]
      args << "--skip=#{pagination[:offset]}" if pagination&.fetch(:offset).to_i.positive?
      args += [ "--max-count=#{limit + 1}", "--pretty=format:#{FORMAT}" ]

      output = @git.run(*args, chdir: bare_clone_path.to_s)
      entries = parse(output)
      visible_entries = entries.first(limit)
      next_cursor = if entries.size > limit
        tip = pagination&.fetch(:tip) || visible_entries.first&.fetch(:sha)
        self.class.cursor_for(tip: tip, offset: (pagination&.fetch(:offset) || 0) + visible_entries.size)
      end

      Page.new(entries: visible_entries, has_more: entries.size > limit, next_cursor: next_cursor)
    rescue GitRunner::GitError
      Page.new(entries: [], has_more: false)
    end

    def self.cursor_for(tip:, offset:)
      "#{tip}:#{offset}" if tip.present? && offset.positive?
    end

    private

    def parse_cursor(cursor)
      return nil unless cursor.present?

      match = CURSOR_PATTERN.match(cursor)
      return nil unless match

      offset = match[:offset].present? ? match[:offset].to_i : 1
      { tip: match[:tip], offset: offset }
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
