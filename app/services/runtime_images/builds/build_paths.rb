module RuntimeImages
  module Builds
    # Validates the user-influenced paths of a build (context directory and
    # Dockerfile). Checks are lexical first, then re-checked against the real
    # filesystem so a symlink inside the source cannot point a build outside it.
    module BuildPaths
      module_function

      def relative!(value, what:)
        path = value.to_s
        raise Rejected.new("path_invalid", "#{what} must not be empty") if path.empty?
        raise Rejected.new("path_invalid", "#{what} contains a NUL byte") if path.include?("\0")
        raise Rejected.new("path_invalid", "#{what} must be relative") if path.start_with?("/") || path.match?(/\A[A-Za-z]:/)
        segments = path.split(%r{[/\\]})
        raise Rejected.new("path_traversal", "#{what} must stay inside the source") if segments.include?("..")
        path
      end

      # Resolves +relative+ under +root+ and returns the real path, or raises
      # unless it exists inside the real root.
      def resolve!(root, relative, what:)
        real_root = File.realpath(root)
        candidate = File.realpath(File.expand_path(relative, real_root))
        unless candidate == real_root || candidate.start_with?("#{real_root}/")
          raise Rejected.new("path_traversal", "#{what} resolves outside the source")
        end
        candidate
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise Rejected.new("path_missing", "#{what} does not exist in the source")
      end
    end
  end
end
