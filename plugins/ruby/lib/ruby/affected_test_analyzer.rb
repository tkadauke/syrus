module Ruby
  # :affected_test_analyzer for plain Ruby repositories (Rails and non-Rails
  # alike). Computes additional spec files transitively affected by a diff's
  # changed Ruby source files, using two real (not glob-guessed) signals:
  #
  #   1. `require_relative` reverse-dependency edges — if changed file B is
  #      require_relative'd by file A, A is also treated as affected, even
  #      though the diff itself never touched A.
  #   2. The standard Rails/RSpec path convention (`app/x/y.rb` <->
  #      `spec/x/y_spec.rb`, `lib/x/y.rb` <-> `spec/lib/x/y_spec.rb`) for
  #      every affected non-spec file, so a change under `app/`/`lib/` maps
  #      to its own spec even when the spec file itself never appears in the
  #      raw diff.
  #
  # Declines (returns nil) when the diff touches no `.rb` files, or when the
  # repo's `app`/`lib` tree is too large to walk with confidence — never
  # raises; `Steps::GraderFanout` treats both as "fall back to glob-only."
  class AffectedTestAnalyzer
    # Repos with more source files than this are outside what a full-tree
    # `require_relative` scan can confidently and cheaply cover on every
    # grader_fanout call; decline rather than guess on a stale/partial graph.
    MAX_SOURCE_FILES = 5_000

    class << self
      def affected_files(repo_path:, changed_files:)
        new(repo_path).affected_files(changed_files)
      end
    end

    def initialize(repo_path)
      @repo_path = Pathname.new(repo_path)
    end

    def affected_files(changed_files)
      ruby_changes = Array(changed_files).select { |f| f.to_s.end_with?(".rb") }
      return nil if ruby_changes.empty?

      source_files = ruby_source_files
      return nil if source_files.size > MAX_SOURCE_FILES

      requirers = reverse_require_graph(source_files)
      impacted = ruby_changes.flat_map { |f| [ f, *requirers[f] ] }.uniq

      impacted.filter_map { |f| conventional_spec_for(f) }
        .select { |spec| @repo_path.join(spec).file? }
        .uniq
    rescue StandardError
      nil
    end

    private

    def ruby_source_files
      Dir.glob(@repo_path.join("{app,lib}/**/*.rb")).map { |f| relative(f) }
    end

    # Builds file -> [files that require_relative it], resolved to
    # repo-relative paths so it can be looked up by the diff's own paths.
    def reverse_require_graph(source_files)
      graph = Hash.new { |h, k| h[k] = [] }

      source_files.each do |file|
        content = safe_read(file)
        next unless content

        dir = Pathname.new(file).dirname
        content.scan(/require_relative\s+["']([^"']+)["']/).each do |(target)|
          resolved = dir.join(target).cleanpath.to_s
          resolved = "#{resolved}.rb" unless resolved.end_with?(".rb")
          graph[resolved] << file
        end
      end

      graph
    end

    def conventional_spec_for(file)
      if file.start_with?("app/")
        file.sub(%r{\Aapp/}, "spec/").sub(/\.rb\z/, "_spec.rb")
      elsif file.start_with?("lib/")
        file.sub(%r{\Alib/}, "spec/lib/").sub(/\.rb\z/, "_spec.rb")
      end
    end

    def safe_read(file)
      @repo_path.join(file).read
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end

    def relative(abs_path)
      Pathname.new(abs_path).relative_path_from(@repo_path).to_s
    end
  end
end
