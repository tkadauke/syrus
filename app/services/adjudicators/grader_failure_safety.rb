module Adjudicators
  module GraderFailureSafety
    def self.failure_explained_by_tests?(grader_step:, run:, grader_name:, test_cases:)
      details = grader_step.details.to_h
      return false unless details["exit_code"].to_i == 1
      return false if details["timed_out"]

      TestEvidenceLookup.test_evidence_providers.any? do |provider|
        provider.respond_to?(:grader_failure_explained_by_tests?) &&
          provider.grader_failure_explained_by_tests?(
            run: run, grader_name: grader_name, failed_test_cases: test_cases
          )
      end
    rescue StandardError
      false
    end

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
