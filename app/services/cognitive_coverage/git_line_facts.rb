require_dependency "cognitive_coverage/snapshot"

module CognitiveCoverage
  class GitLineFacts
    COMPLEXITY_PATTERN = /(\b(if|elsif|case|when|while|until|for|rescue|catch|switch)\b|&&|\|\|)/

    def self.for(workspace_path:, target_sha:, git_runner: GitRunner.new)
      new(workspace_path: workspace_path, target_sha: target_sha, git_runner: git_runner).call
    end

    def initialize(workspace_path:, target_sha:, git_runner:)
      @workspace_path = workspace_path.to_s
      @target_sha = target_sha.to_s
      @git_runner = git_runner
    end

    def call
      paths.flat_map { |path| facts_for_path(path) }
    rescue GitRunner::GitError => e
      Rails.logger.warn("[CognitiveCoverage::GitLineFacts] git scan failed: #{e.message}")
      []
    end

    private

    def paths
      @git_runner.run("ls-tree", "-r", "--name-only", @target_sha, chdir: @workspace_path)
        .lines
        .map(&:strip)
        .reject(&:blank?)
    end

    def facts_for_path(path)
      output = @git_runner.run("blame", "--line-porcelain", @target_sha, "--", path, chdir: @workspace_path)
      parse_blame(path, output)
    rescue GitRunner::GitError
      []
    end

    def parse_blame(path, output)
      current_time = nil
      line_number = 0

      output.each_line.filter_map do |line|
        if line.start_with?("author-time ")
          current_time = Time.zone.at(line.split.last.to_i)
          next
        end

        next unless line.start_with?("\t")

        line_number += 1
        LineFact.new(
          path: path,
          line_number: line_number,
          last_modified_at: current_time,
          complexity: line.match?(COMPLEXITY_PATTERN) ? 1 : 0
        )
      end
    end
  end
end
