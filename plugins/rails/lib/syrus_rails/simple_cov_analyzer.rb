require "json"

module SyrusRails
  # Parses SimpleCov's .resultset.json into the same partial CoverageArtifact
  # hash shape that Steps::CoverageAnalyze uses for summary and files.
  #
  # Output shape (subset of Workflow::CoverageArtifact):
  #   {
  #     "summary" => {
  #       "lines_pct"     => Float | nil,
  #       "branches_pct"  => Float | nil,
  #       "functions_pct" => nil
  #     },
  #     "files" => {
  #       "filepath" => { "lines_pct" => Float | nil, "branches_pct" => Float | nil }
  #     }
  #   }
  class SimpleCovAnalyzer
    # Returns true when this analyzer can handle the given file.
    def self.can_parse?(output_path:, format_hint: nil)
      return true if format_hint.to_s == "simplecov"

      path = output_path.to_s
      return false unless File.basename(path) == ".resultset.json"

      content = File.read(path)
      data    = JSON.parse(content)
      data.is_a?(Hash) && data.values.first.is_a?(Hash) && data.values.first.key?("coverage")
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      false
    end

    def self.call(output_path:, format_hint: nil)
      new(File.read(output_path.to_s)).parse
    end

    def initialize(content)
      @content = content
    end

    def parse
      data = JSON.parse(@content)

      # Merge coverage from all result sets (e.g. RSpec + Cucumber)
      merged = merge_result_sets(data)

      build_artifact(merged)
    end

    private

    def merge_result_sets(data)
      merged_lines    = {}
      merged_branches = {}

      data.each_value do |result_set|
        next unless result_set.is_a?(Hash)

        (result_set["coverage"] || {}).each do |filepath, file_data|
          next unless file_data.is_a?(Hash)

          # Merge line hits (sum across result sets)
          if (lines = file_data["lines"])
            merged_lines[filepath] ||= Array.new(lines.size)
            lines.each_with_index do |hits, i|
              next if hits.nil?

              merged_lines[filepath][i] = (merged_lines[filepath][i] || 0) + hits
            end
          end

          # Merge branch hits (sum across result sets)
          if (branches = file_data["branches"])
            merged_branches[filepath] ||= {}
            branches.each do |key, count|
              merged_branches[filepath][key] = (merged_branches[filepath][key] || 0) + count.to_i
            end
          end
        end
      end

      { lines: merged_lines, branches: merged_branches }
    end

    def build_artifact(merged)
      total_lf = total_lh = 0
      total_brf = total_brh = 0
      files = {}

      merged[:lines].each do |filepath, line_hits|
        file_lf = file_lh = 0

        line_hits.each do |hits|
          next if hits.nil?

          file_lf += 1
          file_lh += 1 if hits > 0
        end

        total_lf += file_lf
        total_lh += file_lh

        file_brf, file_brh = branch_stats(merged[:branches][filepath])
        total_brf += file_brf
        total_brh += file_brh

        files[filepath] = {
          "lines_pct"    => pct(file_lh, file_lf),
          "branches_pct" => pct(file_brh, file_brf)
        }
      end

      {
        "summary" => {
          "lines_pct"     => pct(total_lh, total_lf),
          "branches_pct"  => pct(total_brh, total_brf),
          "functions_pct" => nil
        },
        "files" => files
      }
    end

    def branch_stats(branches)
      return [0, 0] if branches.nil? || branches.empty?

      brf = branches.size
      brh = branches.count { |_, count| count.to_i > 0 }
      [brf, brh]
    end

    def pct(covered, total)
      return nil if total == 0

      (covered.to_f / total * 100).round(2)
    end
  end
end
