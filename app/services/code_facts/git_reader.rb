require "open3"

module CodeFacts
  class GitReader
    FileEntry = Data.define(:path, :size)

    def initialize(path:, git: GitRunner.new)
      @path = path.to_s
      @git = git
    end

    def file_entries_at(sha)
      git.run("ls-tree", "-r", "-l", sha, chdir: path)
        .lines
        .filter_map { |line| parse_ls_tree_line(line) }
    end

    def files_at(sha)
      file_entries_at(sha).map(&:path)
    end

    def file_contents(sha, paths)
      paths = Array(paths).map(&:to_s).reject(&:blank?)
      return {} if paths.empty?

      output = cat_file_batch(paths.map { |file_path| "#{sha}:#{file_path}" })
      parse_cat_file_batch(output, paths)
    end

    def line_counts(sha)
      output = git.run("grep", "-I", "-c", "-e", "", sha, "--", chdir: path)
      parse_path_counts(output, sha)
    rescue GitRunner::GitError
      {}
    end

    def complexity_counts(sha, pattern)
      output = git.run("grep", "-I", "-o", "-E", pattern, sha, "--", chdir: path)
      output.each_line.each_with_object(Hash.new(0)) do |line, counts|
        parsed_path = parse_grep_path(line, sha)
        counts[parsed_path] += 1 if parsed_path.present?
      end
    rescue GitRunner::GitError
      {}
    end

    def last_modified_times(sha)
      output = git.run("log", "--format=%cI", "--name-only", sha, "--", chdir: path)
      current_time = nil

      output.each_line.each_with_object({}) do |line, times|
        value = line.strip
        next if value.empty?

        parsed_time = parse_time(value)
        if parsed_time
          current_time = parsed_time
          next
        end

        file_path = CodeFacts::PathNormalizer.normalize(value)
        times[file_path] ||= current_time if file_path.present? && current_time
      end
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

    def parse_ls_tree_line(line)
      match = line.chomp.match(/\A\d+\s+\w+\s+[0-9a-f]+\s+(\d+|-)\t(.+)\z/)
      return unless match

      FileEntry.new(
        path: CodeFacts::PathNormalizer.normalize(match[2]),
        size: match[1] == "-" ? nil : match[1].to_i
      )
    end

    def parse_path_counts(output, sha)
      output.each_line.each_with_object({}) do |line, counts|
        parsed_path, raw_count = parse_grep_count(line, sha)
        counts[parsed_path] = raw_count.to_i if parsed_path.present?
      end
    end

    def parse_grep_count(line, sha)
      prefix = "#{sha}:"
      value = line.chomp.delete_prefix(prefix)
      parsed_path, raw_count = value.rpartition(":").values_at(0, 2)
      [ CodeFacts::PathNormalizer.normalize(parsed_path), raw_count ]
    end

    def parse_grep_path(line, sha)
      prefix = "#{sha}:"
      CodeFacts::PathNormalizer.normalize(line.chomp.delete_prefix(prefix).split(":", 2).first)
    end

    def parse_time(value)
      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def cat_file_batch(specs)
      output = +""
      status = nil

      Open3.popen3("git", "cat-file", "--batch", chdir: path) do |stdin, stdout, stderr, wait_thr|
        stdin.write(specs.join("\n"))
        stdin.write("\n")
        stdin.close
        output = stdout.read
        output << stderr.read
        status = wait_thr.value
      end

      raise GitRunner::GitError.new([ "cat-file", "--batch" ], status.exitstatus || -1, output) unless status.success?

      output
    end

    def parse_cat_file_batch(output, paths)
      stream = StringIO.new(output)
      paths.each_with_object({}) do |file_path, contents|
        header = stream.gets&.chomp
        break unless header
        next if header.end_with?(" missing")

        _object, type, size = header.split(" ", 3)
        byte_count = size.to_i
        content = stream.read(byte_count)
        stream.read(1)
        contents[file_path] = content if type == "blob"
      end
    end
  end
end
