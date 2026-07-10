module Coverage
  # Parses a unified git diff and annotates changed lines with coverage status.
  # Used by Steps::CoverageAnalyze to produce diff_annotations and pr_delta.
  module DiffAnnotator
    ANNOTATION_COVERED        = "covered"
    ANNOTATION_UNCOVERED      = "uncovered"
    ANNOTATION_NOT_EXECUTABLE = "not_executable"

    module_function

    # diff_text  — output of `git diff <base>...HEAD --unified=0`
    # hit_map    — { "filepath" => { "line_number_str" => hit_count } }
    #
    # Returns [diff_annotations, pr_delta] where:
    #   diff_annotations — { "filepath" => { "12" => "covered"|"uncovered"|"not_executable" } }
    #   pr_delta         — { "covered" => Int, "total" => Int, "pct" => Float|nil, "uncovered_files" => [String] }
    def annotate(diff_text, hit_map)
      diff_annotations = {}
      current_file = nil
      current_new_line = nil
      current_hunk_remaining = 0

      diff_text.each_line do |raw_line|
        line = raw_line.chomp

        # Detect file header: diff --git a/path b/path
        if (m = line.match(/\Adiff --git a\/.+ b\/(.+)/))
          current_file = m[1]
          current_new_line = nil
          current_hunk_remaining = 0
          next
        end

        # Skip binary diffs, index lines, ---/+++ headers
        next if current_file.nil?
        next if line.start_with?("index ", "--- ", "+++ ", "\\", "Binary")

        # Hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
        if (m = line.match(/\A@@ [^+]+ \+(\d+)(?:,(\d+))? @@/))
          current_new_line = m[1].to_i
          current_hunk_remaining = m[2] ? m[2].to_i : 1
          next
        end

        next unless current_new_line && current_hunk_remaining > 0

        if line.start_with?("+")
          line_num_str = current_new_line.to_s
          file_hits = hit_map[current_file] || {}
          annotation = if file_hits.key?(line_num_str)
            file_hits[line_num_str] > 0 ? ANNOTATION_COVERED : ANNOTATION_UNCOVERED
          else
            ANNOTATION_NOT_EXECUTABLE
          end
          diff_annotations[current_file] ||= {}
          diff_annotations[current_file][line_num_str] = annotation
          current_new_line += 1
          current_hunk_remaining -= 1
        elsif line.start_with?("-")
          # Removed line — doesn't advance new-file line numbering
          next
        else
          current_new_line += 1
          current_hunk_remaining -= 1
        end
      end

      pr_delta = compute_pr_delta(diff_annotations)
      [ diff_annotations, pr_delta ]
    end

    def compute_pr_delta(diff_annotations)
      covered = 0
      total   = 0
      uncovered_files = []

      diff_annotations.each do |filepath, lines|
        file_has_uncovered = false
        lines.each_value do |status|
          next if status == ANNOTATION_NOT_EXECUTABLE

          total += 1
          if status == ANNOTATION_COVERED
            covered += 1
          else
            file_has_uncovered = true
          end
        end
        uncovered_files << filepath if file_has_uncovered
      end

      pct = total > 0 ? (covered.to_f / total * 100).round(2) : nil
      { "covered" => covered, "total" => total, "pct" => pct, "uncovered_files" => uncovered_files }
    end
  end
end
