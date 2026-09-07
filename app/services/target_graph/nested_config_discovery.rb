require "find"
require "set"

class TargetGraph
  # Walks a workspace below its root looking for nested `.syrus.yml` files --
  # explicit per-directory configuration declarations, per DOC-20's "First
  # Implementation Slice" step 2. A nested `.syrus.yml` is discovered purely
  # by its literal presence on disk: this never infers a project boundary
  # from `package.json`, `go.mod`, Rails directory conventions, or any other
  # repository-structure signal.
  class NestedConfigDiscovery
    # Directories whose contents are never real project configuration: VCS
    # internals, the workspace's own scratch directory, and common
    # dependency/vendor caches and build outputs. Mirrors the exclusion
    # lists ChatWorkspace and Skills::SecurityReview already use for the
    # same kind of repository-wide walk.
    IGNORED_DIR_NAMES = %w[
      .git .syrus node_modules vendor .bundle tmp log coverage dist build .next .cache
    ].to_set.freeze

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
      relative_dirs = []

      Find.find(workspace_path.to_s) do |path|
        pathname = Pathname.new(path)

        if pathname.directory?
          Find.prune if pathname != workspace_path && IGNORED_DIR_NAMES.include?(pathname.basename.to_s)
          next
        end

        next unless pathname.basename.to_s == SyrusYml::CONFIG_FILE

        relative_dir = pathname.dirname.relative_path_from(workspace_path).to_s
        next if relative_dir == "."

        relative_dirs << relative_dir
      end

      relative_dirs.sort
    end

    private

    attr_reader :workspace_path
  end
end
