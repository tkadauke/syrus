module CoverageAnalysis
  module Parsers
    # Parses LCOV trace files (.info / lcov.info) into a normalized hit map.
    #
    # LCOV record format (one record per source file, separated by end_of_record):
    #   TN:<test name>
    #   SF:<source file path>
    #   DA:<line number>,<hit count>[,<checksum>]
    #   LF:<lines found>
    #   LH:<lines hit>
    #   BRF:<branches found>
    #   BRH:<branches hit>
    #   FNF:<functions found>
    #   FNH:<functions hit>
    #   end_of_record
    class Lcov < Base
      def parse
        hit_map = {}
        file_stats = {}
        total_lf = total_lh = total_brf = total_brh = total_fnf = total_fnh = 0

        current_file = nil
        current_lines = {}
        current_stats = { lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 }

        @content.each_line do |raw_line|
          line = raw_line.chomp
          case line
          when /\ASF:(.+)/
            current_file = Regexp.last_match(1).strip
            current_lines = {}
            current_stats = { lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 }
          when /\ADA:(\d+),(\d+)/
            line_num = Regexp.last_match(1)
            hits    = Regexp.last_match(2).to_i
            current_lines[line_num] = (current_lines[line_num] || 0) + hits
          when /\ALF:(\d+)/
            current_stats[:lf] = Regexp.last_match(1).to_i
          when /\ALH:(\d+)/
            current_stats[:lh] = Regexp.last_match(1).to_i
          when /\ABRF:(\d+)/
            current_stats[:brf] = Regexp.last_match(1).to_i
          when /\ABRH:(\d+)/
            current_stats[:brh] = Regexp.last_match(1).to_i
          when /\AFNF:(\d+)/
            current_stats[:fnf] = Regexp.last_match(1).to_i
          when /\AFNH:(\d+)/
            current_stats[:fnh] = Regexp.last_match(1).to_i
          when "end_of_record"
            next unless current_file

            # Prefer LCOV-reported counts over derived counts when available
            reported_lf = current_stats[:lf] > 0 ? current_stats[:lf] : current_lines.size
            reported_lh = current_stats[:lh] > 0 ? current_stats[:lh] : current_lines.count { |_, c| c > 0 }

            hit_map[current_file] = current_lines.dup
            file_stats[current_file] = current_stats.dup

            total_lf  += reported_lf
            total_lh  += reported_lh
            total_brf += current_stats[:brf]
            total_brh += current_stats[:brh]
            total_fnf += current_stats[:fnf]
            total_fnh += current_stats[:fnh]

            current_file = nil
          end
        end

        build_result(
          hit_map: hit_map,
          lf: total_lf, lh: total_lh,
          brf: total_brf, brh: total_brh,
          fnf: total_fnf, fnh: total_fnh,
          file_stats: file_stats
        )
      end
    end
  end
end
