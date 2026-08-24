module GitHistory
  # Top-level facade the controller calls: pages through CommitLog and
  # attributes each entry via CommitAttributor.
  class Commits
    DEFAULT_LIMIT = 30
    MAX_LIMIT = 100

    Result = Struct.new(:commits, :next_cursor, :has_more, :available, keyword_init: true)

    def self.call(repository:, user:, cursor: nil, limit: DEFAULT_LIMIT)
      new(repository: repository, user: user, cursor: cursor, limit: limit).call
    end

    def initialize(repository:, user:, cursor: nil, limit: DEFAULT_LIMIT, commit_log: nil, attributor: nil)
      @repository = repository
      @user = user
      @cursor = cursor.presence
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @commit_log = commit_log || CommitLog.new(repository: repository)
      @attributor = attributor || CommitAttributor.new(repository: repository, user: user)
    end

    def call
      return unavailable_result unless @commit_log.available?

      page = @commit_log.fetch(cursor: @cursor, limit: @limit)
      commits = page.entries.map { |entry| @attributor.attribute(entry) }
      next_cursor = page.has_more ? page.entries.last[:sha] : nil

      Result.new(commits: commits, next_cursor: next_cursor, has_more: page.has_more, available: true)
    end

    private

    def unavailable_result
      Result.new(commits: [], next_cursor: nil, has_more: false, available: false)
    end
  end
end
