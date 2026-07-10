require "rexml/document"

module CoverageAnalysis
  module Parsers
    # Parses Cobertura XML coverage reports into a normalized hit map.
    #
    # Cobertura format:
    #   <coverage line-rate="0.75" branch-rate="0.5" lines-covered="30" lines-valid="40" ...>
    #     <packages>
    #       <package ...>
    #         <classes>
    #           <class filename="app/models/user.rb" line-rate="0.8" branch-rate="0.6">
    #             <lines>
    #               <line number="1" hits="5" branch="false"/>
    #               <line number="2" hits="0" branch="true" condition-coverage="50% (1/2)"/>
    #             </lines>
    #           </class>
    #         </classes>
    #       </package>
    #     </packages>
    #   </coverage>
    class Cobertura < Base
      def parse
        doc = REXML::Document.new(@content)
        root = doc.root

        hit_map = {}
        file_stats = {}
        total_lf = total_lh = total_brf = total_brh = 0

        REXML::XPath.each(root, "//class") do |klass|
          filename = klass.attributes["filename"].to_s.strip
          next if filename.empty?

          file_lines = {}
          file_lf = file_lh = file_brf = file_brh = 0

          REXML::XPath.each(klass, "lines/line") do |line_el|
            num     = line_el.attributes["number"].to_s
            hits    = line_el.attributes["hits"].to_i
            is_branch = line_el.attributes["branch"] == "true"

            file_lines[num] = (file_lines[num] || 0) + hits
            file_lf += 1
            file_lh += 1 if hits > 0

            if is_branch
              cc = line_el.attributes["condition-coverage"].to_s
              if (m = cc.match(/\((\d+)\/(\d+)\)/))
                file_brh += m[1].to_i
                file_brf += m[2].to_i
              end
            end
          end

          hit_map[filename] = file_lines
          file_stats[filename] = { lf: file_lf, lh: file_lh, brf: file_brf, brh: file_brh, fnf: 0, fnh: 0 }

          total_lf  += file_lf
          total_lh  += file_lh
          total_brf += file_brf
          total_brh += file_brh
        end

        build_result(
          hit_map: hit_map,
          lf: total_lf, lh: total_lh,
          brf: total_brf, brh: total_brh,
          fnf: 0, fnh: 0,
          file_stats: file_stats
        )
      rescue REXML::ParseException => e
        raise ArgumentError, "Cobertura XML parse error: #{e.message}"
      end
    end
  end
end
