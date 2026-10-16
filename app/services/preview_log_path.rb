class PreviewLogPath
  class << self
    def resolve(workspace_path, path, base_path: workspace_path, allow_missing: false)
      real_workspace = File.realpath(workspace_path)
      candidate = File.expand_path(path, base_path)
      return unless lexically_within?(candidate, File.expand_path(workspace_path))

      if File.exist?(candidate)
        real_candidate = File.realpath(candidate)
        return real_candidate if within?(real_candidate, real_workspace)
      elsif allow_missing
        return missing_candidate(candidate, real_workspace)
      end

      nil
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOENT
      nil
    end

    private

    def missing_candidate(candidate, real_workspace)
      candidate_path = Pathname.new(candidate)
      ancestor = candidate_path.dirname
      ancestor = ancestor.dirname until ancestor.exist? || ancestor.root?
      return unless ancestor.exist?

      real_ancestor = File.realpath(ancestor)
      return unless within?(real_ancestor, real_workspace)

      File.join(real_ancestor, candidate_path.relative_path_from(ancestor).to_s)
    end

    def lexically_within?(candidate, workspace)
      candidate == workspace || candidate.start_with?(workspace + File::SEPARATOR)
    end

    def within?(candidate, workspace)
      candidate == workspace || candidate.start_with?(workspace + File::SEPARATOR)
    end
  end
end
