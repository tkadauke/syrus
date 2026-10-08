module CognitiveEngagementEvents
  class DiffSnapshotRanges
    HUNK_HEADER = /\A@@ -(?<old_start>\d+)(?:,(?<old_count>\d+))? \+(?<new_start>\d+)(?:,(?<new_count>\d+))? @@/.freeze

    RangeAnchor = Data.define(:path, :side, :start_line, :end_line)

    def self.changed_ranges_for(version)
      new(version).changed_ranges
    end

    def initialize(version)
      @version = version
    end

    def changed_ranges
      Array(version.files_snapshot).flat_map { |file| ranges_for_file(file) }
    end

    private

    attr_reader :version

    def ranges_for_file(file)
      path = file_value(file, "path")
      patch = file_value(file, "patch").to_s
      return [] if path.blank? || patch.blank?

      old_line = nil
      new_line = nil
      ranges = []
      current = nil

      patch.each_line do |line|
        header = line.match(HUNK_HEADER)
        if header
          ranges << current if current
          current = nil
          old_line = header[:old_start].to_i
          new_line = header[:new_start].to_i
          next
        end

        next if old_line.nil? || new_line.nil?

        case line[0]
        when "+"
          next if line.start_with?("+++")

          current = append_or_flush(ranges, current, path: path, side: "right", line_number: new_line)
          new_line += 1
        when "-"
          next if line.start_with?("---")

          current = append_or_flush(ranges, current, path: path, side: "left", line_number: old_line)
          old_line += 1
        else
          ranges << current if current
          current = nil
          old_line += 1
          new_line += 1
        end
      end

      ranges << current if current
      ranges
    end

    def append_or_flush(ranges, current, path:, side:, line_number:)
      if current && current.path == path && current.side == side && current.end_line + 1 == line_number
        RangeAnchor.new(path: path, side: side, start_line: current.start_line, end_line: line_number)
      else
        ranges << current if current
        RangeAnchor.new(path: path, side: side, start_line: line_number, end_line: line_number)
      end
    end

    def file_value(file, key)
      return file[key] if file.is_a?(Hash) && file.key?(key)
      return file[key.to_sym] if file.is_a?(Hash) && file.key?(key.to_sym)

      file.public_send(key) if file.respond_to?(key)
    end
  end
end
