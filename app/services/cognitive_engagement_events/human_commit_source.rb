module CognitiveEngagementEvents
  class HumanCommitSource
    Commit = Data.define(:sha, :author_name, :author_email, :authored_at, :files)
    FileChange = Data.define(:path, :additions, :deletions)

    def initialize(repository:, user: nil, git: nil, bare_clone: nil)
      @repository = repository
      @user = user || repository.user
      @git = git || GitRunner.new
      @bare_clone = bare_clone || RepositoryBareClone.new(repository, git: @git)
    end

    def each_commit
      sync_bare_clone!
      parse_log.each { |commit| yield commit }
    end

    private

    attr_reader :repository, :user, :git, :bare_clone

    def sync_bare_clone!
      bare_clone.sync!(user: user)
    end

    def parse_log
      output = git.run(
        "log",
        "--numstat",
        "--date=iso-strict",
        "--pretty=format:%x1e%H%x1f%an%x1f%ae%x1f%aI",
        repository.default_branch,
        chdir: bare_clone.path.to_s
      )
      output.to_s.split("\x1e").filter_map { |record| parse_record(record) }
    end

    def parse_record(record)
      lines = record.lines.map(&:chomp).reject(&:blank?)
      header = lines.shift
      return nil if header.blank?

      sha, author_name, author_email, authored_at = header.split("\x1f", 4)
      files = lines.filter_map { |line| parse_numstat(line) }
      return nil if sha.blank? || files.empty?

      Commit.new(
        sha: sha,
        author_name: author_name,
        author_email: author_email,
        authored_at: Time.zone.parse(authored_at),
        files: files
      )
    rescue ArgumentError
      nil
    end

    def parse_numstat(line)
      additions, deletions, path = line.split("\t", 3)
      return nil if path.blank?

      FileChange.new(
        path: normalized_path(path),
        additions: integer_or_zero(additions),
        deletions: integer_or_zero(deletions)
      )
    end

    def normalized_path(path)
      text = path.to_s
      return text unless text.include?("=>")

      brace_match = text.match(/\A(?<prefix>.*)\{[^{}]* => (?<target>[^{}]*)\}(?<suffix>.*)\z/)
      return "#{brace_match[:prefix]}#{brace_match[:target]}#{brace_match[:suffix]}" if brace_match

      text.split(/\s=>\s/, 2).last
    end

    def integer_or_zero(value)
      Integer(value, exception: false) || 0
    end
  end
end
