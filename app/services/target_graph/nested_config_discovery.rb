require "find"
require "set"
require "open3"

class TargetGraph
  # Walks a workspace below its root looking for nested `.syrus.yml` files --
  # explicit per-directory configuration declarations, per DOC-20's "First
  # Implementation Slice" step 2. A nested `.syrus.yml` is discovered purely
  # by its literal presence on disk: this never infers a project boundary
  # from `package.json`, `go.mod`, Rails directory conventions, or any other
  # repository-structure signal.
  class NestedConfigDiscovery
    # Directories that are never real project configuration regardless of
    # what the repository's .gitignore says: VCS internals and the
    # workspace's own scratch directory. Everything else is excluded purely
    # by asking git whether the directory is gitignored -- a nested
    # `.syrus.yml` sitting in a gitignored directory can never be committed,
    # so it can never be an effective declaration.
    ALWAYS_IGNORED_DIR_NAMES = %w[.git .syrus].to_set.freeze

    def self.call(workspace_path)
      new(workspace_path).call
    end

    def initialize(workspace_path)
      @workspace_path = Pathname.new(workspace_path).expand_path
    end

    # Returns relative directory paths (POSIX "/"-joined, no leading or
    # trailing slash) that directly contain a `.syrus.yml` file, sorted
    # lexicographically so callers get a deterministic load order. The
    # workspace root itself is never included -- its `.syrus.yml` is the
    # existing root config, not a nested declaration.
    def call
      candidate_dirs = find_candidate_dirs
      return [] if candidate_dirs.empty?

      ignored = gitignored_dirs(candidate_dirs)
      candidate_dirs.reject { |dir| ignored.include?(dir) }.sort
    end

    private

    attr_reader :workspace_path

    def find_candidate_dirs
      relative_dirs = []

      Find.find(workspace_path.to_s) do |path|
        pathname = Pathname.new(path)

        if pathname.directory?
          Find.prune if pathname != workspace_path && ALWAYS_IGNORED_DIR_NAMES.include?(pathname.basename.to_s)
          next
        end

        next unless pathname.basename.to_s == SyrusYml::CONFIG_FILE

        relative_dir = pathname.dirname.relative_path_from(workspace_path).to_s
        next if relative_dir == "."

        relative_dirs << relative_dir
      end

      relative_dirs
    end

    # Batches every candidate through one `git check-ignore` call (stdin/-z,
    # NUL-delimited both ways) instead of spawning a process per directory.
    # A trailing slash on each candidate tells git to match it as a
    # directory, so directory-only .gitignore patterns (e.g. `build/`) match
    # correctly. Exit status 1 just means "nothing matched" -- not a
    # failure -- and a workspace that isn't a git checkout (or has no git
    # binary) degrades to "nothing is gitignored" rather than raising.
    def gitignored_dirs(relative_dirs)
      stdin_payload = relative_dirs.map { |dir| "#{dir}/\0" }.join
      stdout, = Open3.capture3(
        "git", "check-ignore", "--stdin", "-z",
        chdir: workspace_path.to_s,
        stdin_data: stdin_payload
      )

      stdout.split("\0").map { |dir| dir.delete_suffix("/") }.to_set
    rescue Errno::ENOENT
      Set.new
    end
  end
end
