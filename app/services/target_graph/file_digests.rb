require "digest"
require "pathname"

class TargetGraph
  # The per-file half of a target fingerprint, shared across every target
  # fingerprinted against one unchanging workspace.
  #
  # A fingerprint hashes the files its target's source scope matches, and a
  # target with no declared scope matches every tracked file. Each
  # `Fingerprints` instance used to list and SHA256 the tree on its own, so a
  # grader fan-out that fingerprinted ~150 targets (the CI-phase parity
  # manifest names every target, affected or not) and then fingerprinted the
  # selected ones again for target-health lookups hashed the whole repository
  # a few hundred times. In production that was three to four minutes of
  # every fan-out -- each landing round's -- before a single grader Step
  # existed, for an answer that was the same file digests every time.
  #
  # The values are exactly what `Fingerprints#file_entries` produced per call;
  # only the work is shared. Share one instance only across reads of a
  # workspace that does not change in between (one Step invocation); a new
  # checkout needs a new instance.
  class FileDigests
    attr_reader :workspace_path

    def initialize(workspace_path)
      @workspace_path = Pathname.new(workspace_path)
      @entries = {}
      @matches = {}
    end

    def repository_files
      @repository_files ||= begin
        GitRunner.new.run("ls-files", chdir: workspace_path.to_s).lines.map(&:strip).reject(&:empty?)
      rescue GitRunner::GitError
        Dir.glob("**/*", File::FNM_DOTMATCH, base: workspace_path.to_s)
          .reject { |path| path == "." || path.start_with?(".git/") || path.start_with?(".syrus/") }
          .select { |path| workspace_path.join(path).file? }
      end
    end

    # Tracked files matching any of the source-scope patterns, in
    # `repository_files` order; every tracked file when there are none.
    def matching_files(patterns)
      return repository_files if patterns.empty?

      @matches[patterns.sort] ||= repository_files.select { |path| RepositoryContent::Glob.match?(patterns, path) }
    end

    # Fingerprint entries for the given relative paths, sorted by path, with
    # paths that are not regular files in the workspace omitted.
    def entries_for(paths)
      paths.sort.filter_map { |relative_path| entry(relative_path) }
    end

    private

    def entry(relative_path)
      return @entries[relative_path] if @entries.key?(relative_path)

      absolute_path = workspace_path.join(relative_path)
      @entries[relative_path] = if absolute_path.file?
        {
          "path" => relative_path,
          "sha256" => Digest::SHA256.file(absolute_path).hexdigest,
          "bytes" => absolute_path.size
        }.freeze
      end
    end
  end
end
