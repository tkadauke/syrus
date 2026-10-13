module DiffReviewVersions
  class UnifiedDiffFiles
    DIFF_HEADER = /\Adiff --git (?<old_path>"(?:\\.|[^"\\])*"|a\/.+) (?<new_path>"(?:\\.|[^"\\])*"|b\/.+)\z/
    C_ESCAPES = {
      "a" => "\a",
      "b" => "\b",
      "f" => "\f",
      "n" => "\n",
      "r" => "\r",
      "t" => "\t",
      "v" => "\v",
      "\\" => "\\",
      "\"" => "\""
    }.freeze

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
      path = diff_header_path(match[:new_path], "b/")
      return nil unless path

      patch_lines = lines.drop_while { |line| !line.start_with?("@@") }
      {
        path: path,
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

    def diff_header_path(token, prefix)
      path = c_unquote(token)
      return unless path.start_with?(prefix)

      path.delete_prefix(prefix)
    end

    def c_unquote(token)
      return token unless token.start_with?("\"") && token.end_with?("\"")

      bytes = []
      content = token.byteslice(1...-1)
      index = 0

      while index < content.bytesize
        byte = content.getbyte(index)
        if byte != "\\".ord
          bytes << byte
          index += 1
          next
        end

        index += 1
        escaped = content.byteslice(index, 1)
        break unless escaped

        octal = content.byteslice(index, 3).to_s[/\A[0-7]{1,3}/]
        if octal
          bytes << octal.to_i(8)
          index += octal.length
        else
          bytes.concat(C_ESCAPES.fetch(escaped, escaped).bytes)
          index += 1
        end
      end

      bytes.pack("C*").force_encoding(Encoding::UTF_8).scrub
    end
  end
end
