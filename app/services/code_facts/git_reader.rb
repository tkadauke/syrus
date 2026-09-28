module CodeFacts
  class GitReader
    def initialize(path:, git: GitRunner.new)
      @path = path.to_s
      @git = git
    end

    def files_at(sha)
      git.run("ls-tree", "-r", "--name-only", sha, chdir: path)
        .lines
        .map { |line| CodeFacts::PathNormalizer.normalize(line) }
        .reject(&:blank?)
    end

    def file_content(sha, path)
      git.run("show", "#{sha}:#{path}", chdir: self.path)
    rescue GitRunner::GitError
      nil
    end

    def last_modified_at(sha, path)
      output = git.run("log", "-1", "--format=%cI", sha, "--", path, chdir: self.path).strip
      Time.iso8601(output) if output.present?
    rescue ArgumentError, GitRunner::GitError
      nil
    end

    def churn_counts(sha, windows:, now:)
      windows.index_with do |days|
        since = days.to_i.days.ago(now).utc.iso8601
        output = git.run(
          "log", "--no-merges", "--since=#{since}", "--name-only", "--pretty=format:", sha, "--",
          chdir: path
        )

        output.each_line.each_with_object(Hash.new(0)) do |line, counts|
          file_path = CodeFacts::PathNormalizer.normalize(line)
          counts[file_path] += 1 if file_path.present?
        end
      rescue GitRunner::GitError
        {}
      end
    end

    private

    attr_reader :path, :git
  end
end
