module Syrus
  # Resolves a relative path under a root directory, refusing anything that
  # would escape it (`../` traversal, absolute-path injection, or the root
  # itself). Shared by every call site that previously hand-rolled the same
  # `cleanpath` + `start_with?("#{root}#{File::SEPARATOR}")` idiom.
  class PathJail
    class PathEscape < StandardError
      attr_reader :reason, :relative_path, :root

      # reason is :blank (relative_path was nil/empty) or :escape (resolution
      # left root, including resolving to root itself).
      def initialize(reason:, relative_path:, root:)
        @reason = reason
        @relative_path = relative_path
        @root = root
        super("#{relative_path.inspect} escapes #{root}")
      end
    end

    # Returns the resolved absolute Pathname, or raises PathEscape.
    #
    # relative_path may itself be an absolute path (e.g. a caller re-validating
    # an already-constructed absolute path against root) -- Pathname#join
    # discards `root` in that case, so absolute-path injection is caught by
    # the same escape check as `../` traversal.
    def self.resolve!(root, relative_path)
      if relative_path.blank?
        raise PathEscape.new(reason: :blank, relative_path: relative_path, root: root)
      end

      root = Pathname.new(root.to_s).cleanpath
      candidate = root.join(relative_path.to_s).cleanpath

      if candidate == root || !candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
        raise PathEscape.new(reason: :escape, relative_path: relative_path, root: root)
      end

      candidate
    end
  end
end
