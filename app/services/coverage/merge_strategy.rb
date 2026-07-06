module Coverage
  module MergeStrategy
    module_function

    def merge(raw_a, raw_b)
      all_paths = raw_a[:files].keys | raw_b[:files].keys
      merged_files = all_paths.each_with_object({}) do |path, h|
        h[path] = merge_file(raw_a[:files][path], raw_b[:files][path])
      end
      { files: merged_files }
    end

    def merge_all(raws)
      return { files: {} } if raws.empty?
      raws.reduce { |acc, raw| merge(acc, raw) }
    end

    def merge_file(a, b)
      return b if a.nil?
      return a if b.nil?
      {
        lines: merge_lines(a[:lines], b[:lines]),
        branches: add_counts(a[:branches], b[:branches]),
        functions: add_counts(a[:functions], b[:functions])
      }
    end
    module_function :merge_file

    def merge_lines(a_lines, b_lines)
      (a_lines.keys | b_lines.keys).each_with_object({}) do |num, h|
        h[num] = [ a_lines[num] || 0, b_lines[num] || 0 ].max
      end
    end
    module_function :merge_lines

    def add_counts(a, b)
      return nil if a.nil? && b.nil?
      return a if b.nil?
      return b if a.nil?
      { hit: a[:hit] + b[:hit], found: a[:found] + b[:found] }
    end
    module_function :add_counts
  end
end
