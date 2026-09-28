require_dependency "cognitive_coverage/snapshot"

module CognitiveCoverage
  class LineProjector
    HUNK_HEADER = /\A@@ -(?<old_start>\d+)(?:,(?<old_count>\d+))? \+(?<new_start>\d+)(?:,(?<new_count>\d+))? @@/.freeze

    def initialize(workspace_path:, target_sha:, git_runner: GitRunner.new)
      @workspace_path = workspace_path.to_s.presence
      @target_sha = target_sha.to_s
      @git_runner = git_runner
      @mappings = {}
    end

    def project(engagement)
      return engagement if engagement.line_number.blank?
      return engagement if engagement.source_sha.blank? || engagement.source_sha == @target_sha

      mapped_line = line_mapping_for(engagement.source_sha, engagement.path).call(engagement.line_number.to_i)
      return nil unless mapped_line

      engagement.with(line_number: mapped_line)
    end

    private

    def line_mapping_for(source_sha, path)
      key = [ source_sha, path ]
      @mappings[key] ||= build_mapping(source_sha, path)
    end

    def build_mapping(source_sha, path)
      return ->(_line) { nil } unless @workspace_path

      diff = @git_runner.run(
        "diff", "--unified=0", source_sha, @target_sha, "--", path,
        chdir: @workspace_path
      )
      mapping_from_diff(diff)
    rescue GitRunner::GitError => e
      Rails.logger.warn("[CognitiveCoverage::LineProjector] git diff failed for #{path}: #{e.message}")
      {}
    end

    def mapping_from_diff(diff)
      hunks = diff.each_line.filter_map { |line| parse_hunk(line) }
      return ->(line) { line } if hunks.empty?

      lambda_mapping(hunks)
    end

    def lambda_mapping(hunks)
      lambda do |line|
        offset = 0
        hunks.each do |hunk|
          old_end = hunk[:old_start] + hunk[:old_count] - 1
          return line + offset if line < hunk[:old_start]

          if line <= old_end
            return nil unless hunk[:old_count] == hunk[:new_count]

            return hunk[:new_start] + (line - hunk[:old_start])
          end

          offset += hunk[:new_count] - hunk[:old_count]
        end
        line + offset
      end
    end

    def parse_hunk(line)
      match = line.match(HUNK_HEADER)
      return nil unless match

      {
        old_start: match[:old_start].to_i,
        old_count: (match[:old_count] || "1").to_i,
        new_start: match[:new_start].to_i,
        new_count: (match[:new_count] || "1").to_i
      }
    end
  end
end
