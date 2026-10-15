module Adjudicators
  module GraderFailureSafety
    def self.changed_test_files(workflow:, base_sha:, test_cases:)
      paths = test_cases.filter_map { |test_case| test_case["file_path"].to_s.presence }.uniq
      return [] if paths.empty?
      return paths if base_sha.blank?

      workspace = WorkflowWorkspace.path_for(workflow)
      return paths unless workspace.directory?

      changed = GitRunner.new.run("diff", "--name-only", "#{base_sha}...HEAD", chdir: workspace.to_s)
                         .lines.map(&:strip).reject(&:empty?)
      paths.select { |path| changed.include?(path) }
    rescue GitRunner::GitError
      paths
    end
  end
end
