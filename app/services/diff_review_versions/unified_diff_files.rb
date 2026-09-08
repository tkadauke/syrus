module DiffReviewVersions
  class UnifiedDiffFiles
    DIFF_HEADER = /\Adiff --git a\/(.+) b\/(.+)\z/

    def self.parse(diff)
      new(diff).parse
    end

    def initialize(diff)
      @diff = diff.to_s
    end

    def parse
      sections.filter_map { |section| file_for(section) }
    end

    private

    def sections
      @diff.split(/(?=^diff --git )/)
    end

    def file_for(section)
      lines = section.lines
      header = lines.first.to_s.strip
      match = header.match(DIFF_HEADER)
      return nil unless match

      patch_lines = lines.drop_while { |line| !line.start_with?("@@") }
      {
        path: match[2],
        status: status_for(section),
        additions: patch_lines.count { |line| line.start_with?("+") && !line.start_with?("+++") },
        deletions: patch_lines.count { |line| line.start_with?("-") && !line.start_with?("---") },
        patch: patch_lines.presence&.join
      }
    end

    def status_for(section)
      return "added" if section.include?("\nnew file mode ")
      return "removed" if section.include?("\ndeleted file mode ")
      return "renamed" if section.include?("\nrename from ")

      "modified"
    end
  end
end
